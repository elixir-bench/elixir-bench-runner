defmodule ElixirBench.Runner.ConfigTest do
  use ExUnit.Case, async: true
  import ElixirBench.Runner.Config

  @repo_slug_fixture "elixir-ecto/ecto"
  @branch_fixture "mm/benches"
  @commit_fixture "207b2a0fb5407b7162a454a12bacf8f1a4c962c0"

  @tag requires_internet_connection: true
end
