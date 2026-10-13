defmodule AppChecks.CustomChecksTest do
  # The project's own checks are compiled into the program, so these tests
  # build it. They share one build directory apart from the one the other
  # tests use, since the set of checks in the program changes here.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AppChecks.{Config, Program, TestRepo}

  @moduletag :tmp_dir

  @opts [target_dir: "tmp/custom_checks"]

  # The check from the README, which forbids IO.inspect.
  @no_io_inspect """
  use crate::check::{fast, slow, Check, Config, Files, State, Violation};

  pub struct NoIoInspect;

  pub const CHECK: &dyn Check = &NoIoInspect;

  impl Check for NoIoInspect {
      fn name(&self) -> &'static str {
          "no_io_inspect"
      }

      fn run(&self, state: &State, config: &Config) -> Result<Vec<Violation>, String> {
          let files = state.files(config.scope()).with_extension(&["ex", "exs"]);
          let suspects = fast(config, files, |file| file.contents().contains("IO.inspect"));
          let violations = slow(config, suspects, |file| {
              file.contents()
                  .lines()
                  .enumerate()
                  .filter(|(_, line)| line.contains("IO.inspect") && !line.trim_start().starts_with('#'))
                  .map(|(index, _)| Violation::at(index + 1, "remove the IO.inspect call"))
                  .collect()
          });
          Ok(state.in_scope(config.scope(), violations))
      }
  }

  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::check::testing::{config, run, state};

      #[test]
      fn skips_comments() {
          let state = state().file("a.ex", "# IO.inspect\\nIO.inspect(x)\\n").build();
          assert_eq!(
              run(&NoIoInspect, &state, &config(&NoIoInspect, &[])),
              vec!["a.ex:2: remove the IO.inspect call"]
          );
      }
  }
  """

  test "a check in the custom directory runs with the built-in ones", %{tmp_dir: dir} do
    checks = checks_dir(dir, %{"no_io_inspect.rs" => @no_io_inspect})

    repo =
      TestRepo.create(Path.join(dir, "repo"), %{
        "lib/leftover.ex" => "# IO.inspect\nIO.inspect(x)\n"
      })

    config = config(checks)

    capture_io(fn -> assert :ok = Program.build!(config, @opts) end)

    named = %{
      name: "default",
      base_ref: "base",
      enabled: [%{name: :no_io_inspect, level: :error, scope: :all, config: []}],
      disabled: []
    }

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/found problems/, fn ->
          Program.run!(named, [], [cd: repo] ++ @opts)
        end
      end)

    assert output =~ "lib/leftover.ex:2: remove the IO.inspect call [no_io_inspect, error]"
    assert output =~ "1 check(s), 1 error(s), 0 warning(s), 4 not listed"
  end

  test "mix app_checks.test runs the tests of a custom check", %{tmp_dir: dir} do
    checks = checks_dir(dir, %{"no_io_inspect.rs" => @no_io_inspect})

    output = capture_io(fn -> assert :ok = Program.test!(config(checks), [], @opts) end)

    assert output =~ "no_io_inspect::tests::skips_comments ... ok"
    assert output =~ "check_names_match_file_names ... ok"
  end

  test "a custom check named like a built-in one stops the build", %{tmp_dir: dir} do
    checks = checks_dir(dir, %{"separate_pr.rs" => @no_io_inspect})

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Program.build!(config(checks), @opts) end)
      end

    assert error.message =~ "could not build the checks"
    assert error.message =~ "a built-in check is already called separate_pr, rename the file"
  end

  test "a file name that cannot be a check name stops the build", %{tmp_dir: dir} do
    checks = checks_dir(dir, %{"No-Inspect.rs" => @no_io_inspect})

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Program.build!(config(checks), @opts) end)
      end

    assert error.message =~ "No-Inspect.rs: a check file name must be lower case letters"
  end

  defp config(checks), do: %{Config.defaults() | custom_checks: checks}

  defp checks_dir(dir, files) do
    checks = Path.join(dir, "checks")
    File.mkdir_p!(checks)
    for {name, contents} <- files, do: TestRepo.write(checks, name, contents)
    checks
  end
end
