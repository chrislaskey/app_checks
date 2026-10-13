defmodule AppChecks.ConfigTest do
  use ExUnit.Case, async: true

  alias AppChecks.Config

  doctest Config

  @moduletag :tmp_dir

  @full """
  %{
    custom_checks: "checks",
    configs: [
      %{
        name: "default",
        base_ref: "origin/main",
        paths: ["lib", "config"],
        exclude: ["lib/admin"],
        checks: [
          enabled: [
            :core_component_tags,
            {:no_io_inspect, level: :warning, scope: :changed},
            {:separate_pr, config: [groups: [agents: ["AGENTS.md"]]]}
          ],
          disabled: [:human_review]
        ]
      },
      %{name: "review"}
    ]
  }
  """

  describe "load/1" do
    test "returns the defaults when there is no file" do
      assert Config.load("/no/such/file") == Config.defaults()

      assert Config.defaults() == %{
               custom_checks: "priv/checks",
               configs: [
                 %{
                   name: "default",
                   base_ref: "main",
                   paths: [],
                   exclude: [],
                   enabled: [],
                   disabled: []
                 }
               ]
             }
    end

    test "reads every config and fills in the defaults of each check", %{tmp_dir: dir} do
      assert Config.load(write(dir, @full)) == %{
               custom_checks: "checks",
               configs: [
                 %{
                   name: "default",
                   base_ref: "origin/main",
                   paths: ["lib", "config"],
                   exclude: ["lib/admin"],
                   enabled: [
                     %{name: :core_component_tags, level: :error, scope: :all, config: []},
                     %{name: :no_io_inspect, level: :warning, scope: :changed, config: []},
                     %{
                       name: :separate_pr,
                       level: :error,
                       scope: :all,
                       config: [groups: [agents: ["AGENTS.md"]]]
                     }
                   ],
                   disabled: [:human_review]
                 },
                 %{
                   name: "review",
                   base_ref: "main",
                   paths: [],
                   exclude: [],
                   enabled: [],
                   disabled: []
                 }
               ]
             }
    end

    test "rejects a file that is not a map", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/must be a map/, fn -> Config.load(write(dir, "[]")) end
    end

    test "rejects unknown keys at every level", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/the file has an unknown key :paths/, fn ->
        Config.load(write(dir, ~s|%{paths: ["lib"], configs: [%{name: "default"}]}|))
      end

      assert_raise Mix.Error, ~r/config "default" has an unknown key :base/, fn ->
        Config.load(write(dir, ~s|%{configs: [%{name: "default", base: "main"}]}|))
      end

      assert_raise Mix.Error, ~r/under checks has an unknown key :on/, fn ->
        Config.load(write(dir, ~s|%{configs: [%{name: "default", checks: [on: []]}]}|))
      end

      assert_raise Mix.Error, ~r/for separate_pr has an unknown key :settings/, fn ->
        Config.load(
          write(
            dir,
            ~s|%{configs: [%{name: "default", checks: [enabled: [{:separate_pr, settings: []}]]}]}|
          )
        )
      end
    end

    test "rejects configs without a name, with the same name, or none at all", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/configs must be a list with at least one config/, fn ->
        Config.load(write(dir, "%{configs: []}"))
      end

      assert_raise Mix.Error, ~r/a config needs a name, a string, got nil/, fn ->
        Config.load(write(dir, "%{configs: [%{}]}"))
      end

      assert_raise Mix.Error, ~r/two configs are called "default"/, fn ->
        Config.load(write(dir, ~s|%{configs: [%{name: "default"}, %{name: "default"}]}|))
      end
    end

    test "rejects a bad custom checks directory or base ref", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/custom_checks must be a string/, fn ->
        Config.load(
          write(dir, ~s|%{custom_checks: ["priv/checks"], configs: [%{name: "default"}]}|)
        )
      end

      assert_raise Mix.Error, ~r/base_ref must be a git ref, got :main/, fn ->
        Config.load(write(dir, ~s|%{configs: [%{name: "default", base_ref: :main}]}|))
      end
    end

    test "rejects paths or excludes that are not a list of paths", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/paths must be a list of paths, got "lib"/, fn ->
        Config.load(write(dir, ~s|%{configs: [%{name: "default", paths: "lib"}]}|))
      end

      assert_raise Mix.Error, ~r/exclude must be a list of paths, got \[""\]/, fn ->
        Config.load(write(dir, ~s|%{configs: [%{name: "default", exclude: [""]}]}|))
      end
    end

    test "rejects a bad level, scope, config or entry shape", %{tmp_dir: dir} do
      enabled = fn entries ->
        ~s|%{configs: [%{name: "default", checks: [enabled: #{entries}]}]}|
      end

      assert_raise Mix.Error, ~r/level of a must be one of \[:error, :warning\], got :info/, fn ->
        Config.load(write(dir, enabled.("[{:a, level: :info}]")))
      end

      assert_raise Mix.Error, ~r/scope of a must be one of \[:all, :changed\], got :branch/, fn ->
        Config.load(write(dir, enabled.("[{:a, scope: :branch}]")))
      end

      assert_raise Mix.Error, ~r/config of a must be a keyword list, got "x"/, fn ->
        Config.load(write(dir, enabled.(~s|[{:a, config: "x"}]|)))
      end

      assert_raise Mix.Error,
                   ~r/an enabled check is a name or a \{name, options\} tuple, got "a"/,
                   fn ->
                     Config.load(write(dir, enabled.(~s|["a"]|)))
                   end

      assert_raise Mix.Error, ~r/options of a must be a keyword list/, fn ->
        Config.load(write(dir, enabled.(~s|[{:a, "x"}]|)))
      end
    end

    test "rejects a check listed twice or both enabled and disabled", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/a is enabled twice/, fn ->
        Config.load(
          write(dir, ~s|%{configs: [%{name: "default", checks: [enabled: [:a, {:a, []}]]}]}|)
        )
      end

      assert_raise Mix.Error, ~r/a is both enabled and disabled/, fn ->
        Config.load(
          write(
            dir,
            ~s|%{configs: [%{name: "default", checks: [enabled: [:a], disabled: [:a]]}]}|
          )
        )
      end

      assert_raise Mix.Error, ~r/disabled must list check names, got "a"/, fn ->
        Config.load(write(dir, ~s|%{configs: [%{name: "default", checks: [disabled: ["a"]]}]}|))
      end
    end
  end

  describe "named/2" do
    test "finds a config by name and says which there are otherwise", %{tmp_dir: dir} do
      config = Config.load(write(dir, @full))

      assert Config.named(config, "review").name == "review"

      assert_raise Mix.Error,
                   ~r/no config called "nope".*the configs are: "default", "review"/,
                   fn ->
                     Config.named(config, "nope")
                   end
    end
  end

  describe "flatten/1" do
    test "is empty for no config" do
      assert Config.flatten([]) == []
    end
  end

  defp write(dir, contents) do
    path = Path.join(dir, ".app_checks.exs")
    File.write!(path, contents)
    path
  end
end
