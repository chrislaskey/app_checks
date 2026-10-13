defmodule AppChecks.ProgramTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AppChecks.{Config, Program, TestRepo}

  @moduletag :tmp_dir

  # In this library priv/checks is the crate itself, so the custom checks
  # directory points at one that does not exist.
  @config %{Config.defaults() | custom_checks: "test/fixtures/custom_checks"}

  # The components module the tag check reads: a fixture that defines
  # `button/1` and `input/1`, by an absolute path since the program runs
  # inside a throwaway repository.
  @components Path.expand("test/fixtures/core_components.ex")
  @tags %{name: :core_component_tags, level: :error, scope: :all, config: [paths: [@components]]}
  @separate_pr %{
    name: :separate_pr,
    level: :error,
    scope: :all,
    config: [groups: [agents: ["AGENTS.md"]]]
  }

  setup_all do
    capture_io(fn -> Program.build!(@config) end)
    :ok
  end

  describe "arguments/3" do
    test "turns a config into flags: enable, level, scope and keys per check, then disable" do
      named = %{
        name: "default",
        base_ref: "origin/develop",
        enabled: [
          %{name: :a, level: :warning, scope: :changed, config: [paths: ["x", "y"]]},
          %{name: :b, level: :error, scope: :all, config: []}
        ],
        disabled: [:c]
      }

      assert Program.arguments(named, ["lib", "test"]) == [
               "--base",
               "origin/develop",
               "--enable",
               "a",
               "--level",
               "a=warning",
               "--scope",
               "a=changed",
               "--set",
               "a.paths=x",
               "--set",
               "a.paths=y",
               "--enable",
               "b",
               "--level",
               "b=error",
               "--scope",
               "b=all",
               "--disable",
               "c",
               "lib",
               "test"
             ]
    end

    test "the options override the base, narrow to one check and set every scope" do
      named = %{name: "default", base_ref: "main", enabled: [entry(:a), entry(:b)], disabled: []}

      args =
        Program.arguments(named, [], base: "feature", check: "b", scope: :changed, verbose: true)

      assert args == [
               "--base",
               "feature",
               "--verbose",
               "--enable",
               "b",
               "--level",
               "b=error",
               "--scope",
               "b=changed"
             ]
    end

    test "the config's excludes always apply, and paths given replace the config's" do
      named = %{
        name: "default",
        base_ref: "main",
        paths: ["lib", "config"],
        exclude: ["lib/admin", "lib/tmp"],
        enabled: [],
        disabled: []
      }

      exclude = ["--exclude", "lib/admin", "--exclude", "lib/tmp"]

      assert Program.arguments(named, []) ==
               ["--base", "main"] ++ exclude ++ ["lib", "config"]

      assert Program.arguments(named, ["test"]) == ["--base", "main"] ++ exclude ++ ["test"]
    end

    test "a check the config does not enable is an error" do
      named = %{name: "default", base_ref: "main", enabled: [entry(:a)], disabled: []}

      assert_raise Mix.Error,
                   ~r/b is not enabled in the config "default"; the enabled checks are: a/,
                   fn ->
                     Program.arguments(named, [], check: "b")
                   end
    end
  end

  describe "target_dir/1 and binary/1" do
    test "build under _build unless told otherwise" do
      assert Program.target_dir() == Path.expand("_build/test/app_checks")
      assert Program.binary() == Path.expand("_build/test/app_checks/release/checks")
      assert Program.binary(target_dir: "tmp/x") == Path.expand("tmp/x/release/checks")
    end
  end

  # The program reads every file and every change from git, so each test
  # runs it inside a throwaway repository: lib/page.html.heex is committed
  # with a raw <button> on line 2, lib/other.html.heex with one on line 1.
  #
  # Output is captured from this process rather than by swapping the global
  # Mix shell, which would also redirect output from concurrent tests.
  describe "run!/3" do
    setup %{tmp_dir: dir} do
      TestRepo.create(dir, %{
        "lib/page.html.heex" => "<div>\n  <button>Old</button>\n</div>\n",
        "lib/other.html.heex" => "<button>Old</button>\n",
        "AGENTS.md" => "rules\n"
      })

      :ok
    end

    test "passes when nothing is enabled, and counts the checks it did not run", %{tmp_dir: dir} do
      output = capture_io(fn -> assert :ok = run(dir, []) end)

      assert output =~ "0 check(s), 0 error(s), 0 warning(s), 4 not listed"
    end

    test "fails on an error, printing each violation with the check and level", %{tmp_dir: dir} do
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found problems/, fn -> run(dir, [@tags]) end
        end)

      assert output =~
               "lib/page.html.heex:2: <button> is a raw tag, use <.button> from ExampleWeb.CoreComponents [core_component_tags, error]"

      assert output =~ "lib/other.html.heex:1: <button> is a raw tag"
      assert output =~ "1 check(s), 2 error(s), 0 warning(s), 3 not listed"
    end

    test "a warning prints and passes", %{tmp_dir: dir} do
      output = capture_io(fn -> assert :ok = run(dir, [%{@tags | level: :warning}]) end)

      assert output =~ "[core_component_tags, warning]"
      assert output =~ "1 check(s), 0 error(s), 2 warning(s)"
    end

    test "the changed scope reports only the lines the branch changed", %{tmp_dir: dir} do
      TestRepo.write(
        dir,
        "lib/page.html.heex",
        "<div>\n  <button>Old</button>\n  <button>New</button>\n</div>\n"
      )

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found problems/, fn ->
            run(dir, [%{@tags | scope: :changed}])
          end
        end)

      assert output =~ "lib/page.html.heex:3: <button> is a raw tag"
      refute output =~ "lib/page.html.heex:2:"
      refute output =~ "lib/other.html.heex"
      assert output =~ "1 check(s), 1 error(s)"
    end

    test "scope: in the options overrides every check", %{tmp_dir: dir} do
      TestRepo.write(
        dir,
        "lib/page.html.heex",
        "<div>\n  <button>Old</button>\n  <button>New</button>\n</div>\n"
      )

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found problems/, fn -> run(dir, [@tags], scope: :changed) end
        end)

      assert output =~ "1 check(s), 1 error(s)"
    end

    test "check: runs one enabled check on its own", %{tmp_dir: dir} do
      TestRepo.write(dir, "lib/a.ex", "x\n")

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found problems/, fn ->
            run(dir, [@tags, @separate_pr], check: "core_component_tags")
          end
        end)

      assert output =~ "1 check(s), 2 error(s), 0 warning(s), 3 not listed"
    end

    test "verbose prints every stage", %{tmp_dir: dir} do
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found problems/, fn -> run(dir, [@tags], verbose: true) end
        end)

      assert output =~ "lib/page.html.heex: kept by the fast pass [core_component_tags, fast]"

      assert output =~
               "lib/page.html.heex:2: <button> is a raw tag, use <.button> from ExampleWeb.CoreComponents [core_component_tags, slow]"

      assert output =~
               "lib/page.html.heex:2: <button> is a raw tag, use <.button> from ExampleWeb.CoreComponents [core_component_tags, error]"
    end

    test "paths narrow the run", %{tmp_dir: dir} do
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found problems/, fn ->
            run(dir, [@tags], paths: ["lib/other.html.heex"])
          end
        end)

      assert output =~ "lib/other.html.heex:1:"
      refute output =~ "lib/page.html.heex"
    end

    test "excludes leave paths out of the run", %{tmp_dir: dir} do
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found problems/, fn ->
            run(dir, [@tags], exclude: ["lib/page.html.heex"])
          end
        end)

      assert output =~ "lib/other.html.heex:1:"
      refute output =~ "lib/page.html.heex"
    end

    test "a review check reads the branch whatever its scope", %{tmp_dir: dir} do
      TestRepo.write(dir, "AGENTS.md", "new rules\n")
      TestRepo.write(dir, "lib/a.ex", "x\n")

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found problems/, fn -> run(dir, [@separate_pr]) end
        end)

      assert output =~
               ~s|lib/a.ex: AGENTS.md is in the group "agents", so it must be the only change; move this file to its own branch [separate_pr, error]|

      assert output =~ "1 check(s), 1 error(s)"
    end

    test "a bad config key, a bad value and a missing base are errors", %{tmp_dir: dir} do
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/could not run/, fn ->
            run(dir, [%{@tags | config: [nope: ["x"]]}])
          end
        end)

      assert output =~ "core_component_tags does not accept nope"

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/could not run/, fn ->
            run(dir, [%{@separate_pr | config: []}])
          end
        end)

      assert output =~ "separate_pr: set groups.NAME to the files in each group"

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/could not run/, fn -> run(dir, [@tags], base: "nope") end
        end)

      assert output =~ "could not find where the branch left nope"
    end
  end

  defp entry(name), do: %{name: name, level: :error, scope: :all, config: []}

  defp run(dir, enabled, opts \\ []) do
    {paths, opts} = Keyword.pop(opts, :paths, [])
    {exclude, opts} = Keyword.pop(opts, :exclude, [])
    named = %{name: "default", base_ref: "base", exclude: exclude, enabled: enabled, disabled: []}
    Program.run!(named, paths, [cd: dir] ++ opts)
  end
end
