<img src="https://github.com/elixir-bench/elixir-bench.github.io/blob/master/images/logo.png" height="68" />

# ElixirBench Runner

[![Travis build](https://secure.travis-ci.org/elixir-bench/elixir-bench-runner.svg?branch=master
"Build Status")](https://travis-ci.org/elixir-bench/elixir-bench-runner)

This is an Elixir daemon that pulls for job our API and executes tests in `runner-container`.

## Dependencies

Benchmarks are running inside a docker container, so you need to have
[`docker`](https://docs.docker.com/engine/installation/) and
[`docker-compose`](https://docs.docker.com/compose/install/) installed.

## Deployment

This project uses `distillery` for deployments. Built releases are placed under `_build/prod/rel/runner`
directory. To build the release you can use the command below:

```bash
$ MIX_ENV=prod mix release --env=prod
```

There are also some environment variables that can be set when running the project:

|       NAME       |               Description        |                 Default                |
|:----------------:|:--------------------------------:|:--------------------------------------:|
| `RUNNER_API_URL` |         url for the api server   | https://api.elixirbench.org/runner-api |
| `RUNNER_API_USER`|   username for authentication    |               test-runner              |
| `RUNNER_API_KEY` | password key for authentication  |                  test                  |

Set the variables and start the application with the command:

```bash
RUNNER_API_URL=api.elixirbench.org/runner-api RUNNER_API_USER=test-runner RUNNER_API_KEY=test _build/prod/rel/runner/bin/runner foreground
```

The API Server needs to have proper credentials for the runner configured as well.
This can be done from the release console using:

```elixir
ElixirBench.Benchmarks.create_runner(%{name: test-runner, api_key: test})
```

## License

ElixirBench Runner is released under the Apache 2.0 License - see the [LICENSE](LICENSE.md) file.
