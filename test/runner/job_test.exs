defmodule ElixirBench.Runner.JobTest do
  use ExUnit.Case
  alias ElixirBench.Runner.Job

  @moduletag timeout: :infinity

  @tag docker_integration: true, capture_log: true
  test "run_job/1" do
    job = Job.run_job(job_fixture())

    assert job.status == 0
    assert job.log =~ "Cloning the repo.."
    assert length(job.measurements) > 1

    # Make sure context is present
    assert is_binary(Keyword.fetch!(job.context.mix_deps, :benchee))
    assert is_binary(job.context.worker_available_memory)
    assert is_binary(job.context.worker_cpu_speed)
    assert job.context.worker_num_cores in 1..64
    assert job.context.worker_os in [:Linux, :Windows, :macOS]
  end

  describe "start_job/6" do
    test "run job and return results given execute function" do
      task_fun = fn job ->
        {:ok, %{job | log: "success", status: 0}}
      end

      {:ok, job} = Job.start_job(job_fixture(), task_fun: task_fun)

      assert %{log: "success", status: 0} = job
    end

    test "not start job if there is other job running" do
      task_fun = fn _job ->
        :timer.sleep(2_000)
        {:ok, %{}}
      end

      %{pid: pid} =
        Task.Supervisor.async_nolink(ElixirBench.Runner.JobsSupervisor, fn ->
          :timer.sleep(2_000)
        end)

      assert_raise MatchError, fn ->
        Job.start_job(job_fixture(), task_fun: task_fun)
      end

      Process.exit(pid, :kill)
    end

    test "handle job timeout" do
      task_fun = fn _job ->
        :timer.sleep(2_000)
        {:ok, %{}}
      end

      job = Job.start_job(job_fixture(), task_fun: task_fun, timeout: 100)

      assert %{log: "Job execution timed out", status: 127} = job
    end
  end

  describe "ensure_no_other_jobs!/0" do
    test "raise error if active child process already exist under JobsSupervisor" do
      assert %{active: 0} = Job.ensure_no_other_jobs!()

      %{pid: pid} =
        Task.Supervisor.async_nolink(ElixirBench.Runner.JobsSupervisor, fn ->
          :timer.sleep(3_000)
        end)

      assert_raise MatchError, fn ->
        Job.ensure_no_other_jobs!()
      end

      Process.exit(pid, :kill)
    end
  end

  describe "get_benchmars_output_path/1" do
    test "return path for writing benchmark results" do
      env_backup = Application.get_env(:runner, :benchmars_output_path)
      Application.put_env(:runner, :benchmars_output_path, "/tmp")

      assert "/tmp/test_job" = Job.get_benchmars_output_path(job_fixture())

      Application.put_env(:runner, :benchmars_output_path, env_backup)
    end

    test "raise if output path not defined" do
      env_backup = Application.get_env(:runner, :benchmars_output_path)
      Application.delete_env(:runner, :benchmars_output_path)

      assert_raise ArgumentError, fn ->
        Job.get_benchmars_output_path(job_fixture())
      end

      Application.put_env(:runner, :benchmars_output_path, env_backup)
    end
  end

  describe "get_compose_config/1" do
    test "return docker-compose setup for simple job" do
      job = job_fixture()

      compose_config =
        Job.get_compose_config(job)
        |> Antidote.decode!()

      assert %{
               "services" => %{
                 "runner" => %{
                   "image" => "elixirbench/runner:1.5.2-20.1.2",
                   "command" => "mix run bench/bench_helper.exs",
                   "network_mode" => "host",
                   "environment" => %{
                     "ELIXIRBENCH_REPO_SLUG" => "elixir-ecto/ecto",
                     "ELIXIRBENCH_REPO_BRANCH" => "mm/benches",
                     "ELIXIRBENCH_REPO_COMMIT" => "2a5a8efbc3afee3c6893f4cba33679e98142df3f"
                   },
                   "volumes" => [
                     "/tmp/benchmarks/test_job:/var/bench:Z"
                   ]
                 }
               },
               "version" => "3"
             } = compose_config
    end

    test "return docker-compose setup for job with deps and environment variables" do
      job = job_fixture() |> with_deps |> with_env_variables
      timeout = 200

      compose_config =
        Job.get_compose_config(job)
        |> Antidote.decode!()

      %{"services" => services} = compose_config

      assert %{"job_test_job_mysql" => _mysql} = services
      assert %{"job_test_job_postgres" => _postgres} = services

      %{"runner" => %{"command" => command}} = services

      assert command =~
               "wait-for.sh localhost:3306 -t #{timeout} -- wait-for.sh localhost:5432 -t #{
                 timeout
               } -- mix run bench/bench_helper.exs"

      assert %{"runner" => %{"depends_on" => ["job_test_job_mysql", "job_test_job_postgres"]}} =
               services

      assert %{"runner" => %{"environment" => %{"PG_URL" => "postgres:postgres@localhost"}}} =
               services

      assert %{"runner" => %{"environment" => %{"MYSQL_URL" => "root@localhost"}}} = services
    end
  end

  describe "format_measurement/2" do
    test "extract and format measurements information for benchmark given valid input" do
      benchmark_name = "insert_mysql"
      measurements = measurement_fixture()

      %{
        "statistics" => %{
          "insert_changeset" => insert_changeset,
          "insert_plain" => insert_plain
        }
      } = measurements

      formatted_measurements = Job.format_measurement(measurements, benchmark_name)

      assert %{"insert_mysql/insert_changeset" => ^insert_changeset} = formatted_measurements
      assert %{"insert_mysql/insert_plain" => ^insert_plain} = formatted_measurements

      measurements = Job.format_measurement(measurement_fixture(), "")

      assert %{"/insert_changeset" => _} = measurements
      assert %{"/insert_plain" => _} = measurements
    end

    test "return empty map given invalid inputs" do
      assert %{} = Job.format_measurement(measurement_fixture(), nil)
      assert %{} = Job.format_measurement(%{}, "insert_mysql")

      assert %{} = Job.format_measurement(nil, "insert_mysql")
      assert %{} = Job.format_measurement(%{"a" => "b"}, "insert_mysql")
    end
  end

  def measurement_fixture do
    %{
      "statistics" => %{
        "insert_changeset" => %{
          "average" => 66025.6447368421,
          "ips" => 15.145630216648275,
          "maximum" => 298_716.0,
          "median" => 49266.5,
          "minimum" => 48642.0,
          "mode" => 49141.0,
          "percentiles" => %{"50" => 49266.5, "99" => 298_716.0},
          "sample_size" => 76,
          "std_dev" => 49623.892744827106,
          "std_dev_ips" => 11.383230446584102,
          "std_dev_ratio" => 0.7515851294237665
        },
        "insert_plain" => %{
          "average" => 61939.7037037037,
          "ips" => 16.144733348800386,
          "maximum" => 320_994.0,
          "median" => 49262.0,
          "minimum" => 48727.0,
          "mode" => [49179.0, 49222.0, 49020.0, 49128.0],
          "percentiles" => %{"50" => 49262.0, "99" => 320_994.0},
          "sample_size" => 81,
          "std_dev" => 43170.800977605344,
          "std_dev_ips" => 11.252573528147071,
          "std_dev_ratio" => 0.6969810702375694
        }
      }
    }
  end

  def job_fixture do
    config = %ElixirBench.Runner.Config{
      deps: [],
      environment_variables: %{},
      elixir_version: "1.5.2",
      erlang_version: "20.1.2"
    }

    %Job{
      id: "test_job",
      repo_slug: "elixir-ecto/ecto",
      branch: "mm/benches",
      commit: "2a5a8efbc3afee3c6893f4cba33679e98142df3f",
      config: config,
      log: nil,
      status: nil
    }
  end

  def with_deps(%Job{} = job) do
    deps = [
      %{
        "container_name" => "postgres",
        "image" => "postgres:9.6.6-alpine",
        "wait" => %{"port" => "5432"}
      },
      %{
        "container_name" => "mysql",
        "environment" => %{"MYSQL_ALLOW_EMPTY_PASSWORD" => "true"},
        "image" => "mysql:5.7.20",
        "wait" => %{"port" => "3306"}
      }
    ]

    %{job | config: %{job.config | deps: deps}}
  end

  def with_env_variables(%Job{} = job) do
    env_vars = %{
      "MYSQL_URL" => "root@localhost",
      "PG_URL" => "postgres:postgres@localhost"
    }

    %{job | config: %{job.config | environment_variables: env_vars}}
  end
end
