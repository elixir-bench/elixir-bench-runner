defmodule ElixirBench.Runner.ConfigTest do
  use ExUnit.Case, async: true
  

  @repo_owner "elixir-ecto"
  @repo_name "ecto"
  @branch_fixture "mm/benches"
  @commit_fixture "207b2a0fb5407b7162a454a12bacf8f1a4c962c0"

  @tag requires_internet_connection: true
  describe "fetch_config_by_repo_slug/1" do
    test "loads configuration from repo" do
      assert {:ok, _} = Github.fetch_config(@repo_owner, @repo_name, @branch_fixture)
      assert {:ok, _} = Github.fetch_config(@repo_owner, @repo_name, @commit_fixture)
    end

    test "returns error when file does not exist" do
      assert Github.fetch_config("elixir-ecto", "ecto", "not_a_branch") == {:error, :failed_config_fetch}
      assert Github.fetch_config("not-elixir", "ecto/ecto", "mm/benches") == {:error, :failed_config_fetch}
      assert Github.fetch_config("not-elixir", "-ecto", "/ecto") == {:error, :failed_config_fetch}
    end
  end
end
