defmodule ElixirBench.Runner.Job do
  @moduledoc """
  This module is responsible for starting and halting jobs.

  Under the hood it's using CLI integration to docker-compose.
  """
  alias ElixirBench.Runner.{Job, Config}

  defstruct id: nil,
            repo_slug: nil,
            branch: nil,
            commit: nil,
            config: %Config{},
            status: nil,
            log: nil,
            context: %{},
            measurements: %{}

  # --force-recreate -          Recreate containers even if their configuration and image haven't changed;
  # --no-build -                We don't allow users to use our benchmarking service to build images,
  #                             TODO: warn when `build` config key is present in docker deps;
  # --abort-on-container-exit - Stops all containers when one of them exists,
  #                             this allows us to shut down all deps when benchmarks are completed;
  # --remove-orphans -          Remove containers for services not defined in the Compose file.
  @static_compose_args ~w[up --force-recreate --no-build --abort-on-container-exit --remove-orphans]

  # Both host and container:runner network modes are allowing
  # to use localhost for sending requests to a helper container,
  # with following cons:
  # * `container:runner` network mode violates start order,
  # so runner is started before DB's, but source pooling saves the day;
  # * `host` binds to all host interfaces, which is not best for
  # security but gives better performance.
  @network_mode "host"

  @doc """
  Executes a benchmarking job for a specific commit.
  """
  def start_job(job, runner_fun \\ &run_job/1) do
    ensure_no_other_jobs!()

    timeout = Confex.fetch_env!(:runner, :job_timeout)

    task =
      Task.Supervisor.async_nolink(ElixirBench.Runner.JobsSupervisor, fn ->
        runner_fun.(job)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        %{job | status: 127, log: "Job execution timed out"}
    end
  end

  defp ensure_no_other_jobs! do
    %{active: 0} = Supervisor.count_children(ElixirBench.Runner.JobsSupervisor)
  end

  @doc false
  def run_job(job) do
    benchmarks_output_path = get_benchmarks_output_path(job)
    File.mkdir_p!(benchmarks_output_path)

    compose_config = get_compose_config(job)
    compose_config_path = "#{benchmarks_output_path}/#{job.id}-config.yml"
    File.write!(compose_config_path, compose_config)

    try do
      {log, status} =
        System.cmd("docker-compose", ["-f", compose_config_path] ++ @static_compose_args)

      measurements = collect_measurements(benchmarks_output_path)
      context = collect_context(benchmarks_output_path)
      %{job | log: log, status: status, measurements: measurements, context: context}
    after
      # Stop all containers and delete all containers, images and build cache
      {_log, 0} = System.cmd("docker", ~w[system prune -a -f])

      # Clean benchmarking temporary files
      File.rm_rf!(benchmarks_output_path)
    end
  end

  def get_benchmarks_output_path(%Job{id: id}) do
    Confex.fetch_env!(:runner, :benchmarks_output_path) <> "/" <> id
  end

  @doc false
  def get_compose_config(job) do
    Antidote.encode!(%{version: "3", services: build_services(job)})
  end

  defp build_services(job) do
    %{id: id, config: config} = job

    services =
      config.deps
      |> Enum.reduce(%{}, fn dep, services ->
        dep = Map.put(dep, "network_mode", @network_mode)
        name = "job_" <> id <> "_" <> get_dep_container_name(dep)
        Map.put(services, name, dep)
      end)

    Map.put(services, "runner", build_runner_service(job, services))
    |> delete_non_docker_tag("wait")
  end

  defp get_dep_container_name(%{"container_name" => container_name}), do: container_name
  defp get_dep_container_name(%{"image" => image}), do: dep_name_from_image(image)

  defp build_runner_service(job, deps) do
    container_benchmarks_output_path =
      Confex.fetch_env!(:runner, :container_benchmarks_output_path)

    %{
      network_mode: @network_mode,
      image: "elixirbench/runner:#{job.config.elixir_version}-#{job.config.erlang_version}",
      volumes: ["#{get_benchmarks_output_path(job)}:#{container_benchmarks_output_path}:Z"],
      depends_on: Map.keys(deps),
      environment: build_runner_environment(job),
      command: build_runner_command_from_deps(deps)
    }
  end

  defp build_runner_command_from_deps(deps) do
    wait_command =
      Enum.reduce(deps, "", fn {_dep_name, dep_params}, command ->
        wait_port = get_in(dep_params, ["wait", "port"])

        case wait_port do
          nil -> command
          port -> command <> "wait-for.sh localhost:#{port} -t 200 -- "
        end
      end)

    wait_command <> "mix run bench/bench_helper.exs"
  end

  defp build_runner_environment(job) do
    %{repo_slug: repo_slug, branch: branch, commit: commit, config: config} = job

    config.environment_variables
    |> Map.put("ELIXIRBENCH_REPO_SLUG", repo_slug)
    |> Map.put("ELIXIRBENCH_REPO_BRANCH", branch)
    |> Map.put("ELIXIRBENCH_REPO_COMMIT", commit)
  end

  defp dep_name_from_image(image) do
    [slug | _tag] = String.split(image, ":")
    slug |> String.split("/") |> List.last()
  end

  defp collect_measurements(benchmarks_output_path) do
    "#{benchmarks_output_path}/*.json"
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, acc ->
      benchmark_name = Path.basename(path, ".json")
      new_data = path |> File.read!() |> Antidote.decode!() |> format_measurement(benchmark_name)
      Map.merge(acc, new_data)
    end)
  end

  # From benchee we are just interested on measurement statistics, so ignore the rest
  @doc false
  def format_measurement(measurement, benchmark_name)
      when is_map(measurement) and is_binary(benchmark_name) do
    statistics = Map.get(measurement, "statistics")

    case is_map(statistics) do
      true ->
        Map.new(statistics, fn {name, data} -> {"#{benchmark_name}/#{name}", data} end)

      false ->
        %{}
    end
  end

  def format_measurement(_measurement, _benchmark_name), do: %{}

  defp collect_context(benchmarks_output_path) do
    mix_deps = read_mix_deps("#{benchmarks_output_path}/mix.lock")

    %{
      dependency_versions: mix_deps,
      cpu_count: Benchee.System.num_cores(),
      worker_os: Benchee.System.os(),
      memory: Benchee.System.available_memory(),
      cpu: Benchee.System.cpu_speed()
    }
  end

  # Delete key that is not allowed in docker-compose otherwise it will break.
  # This function iterates recursively over the services map and nested maps to delete the
  # key for all services.
  defp delete_non_docker_tag(services, tag) when is_map(services) do
    Map.delete(services, tag)
    |> Enum.reduce(%{}, fn {service_name, service_params}, cleaned_map ->
      Map.put(cleaned_map, service_name, delete_non_docker_tag(service_params, tag))
    end)
  end

  defp delete_non_docker_tag(value, _tag), do: value

  def read_mix_deps(file) do
    case File.read(file) do
      {:ok, info} ->
        case Code.eval_string(info, [], file: file) do
          {lock, _binding} when is_map(lock) ->
            Map.new(lock, fn
              {dep_name, ast} when elem(ast, 0) == :git ->
                {dep_name, elem(ast, 1)}

              {dep_name, ast} when elem(ast, 0) == :hex ->
                {dep_name, elem(ast, 2)}

              {dep_name, ast} when elem(ast, 0) == :path ->
                {dep_name, elem(ast, 1)}
            end)

          {_, _binding} ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end
end
