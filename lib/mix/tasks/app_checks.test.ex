defmodule Mix.Tasks.AppChecks.Test do
  @shortdoc "Runs the Rust tests of every check, built-in and the project's own"

  @moduledoc """
  Runs `cargo test` over the checks: the built-in ones and the project's
  own in `priv/checks`, read from `.app_checks.exs` like `mix app_checks`.

      $ mix app_checks.test
      $ mix app_checks.test no_io_inspect   # only tests whose name contains this

  Everything after the task name is passed on to `cargo test`. A check's
  tests live at the bottom of its file, see the README for how to write
  them.
  """

  use Mix.Task

  alias AppChecks.{Config, Program}

  @impl Mix.Task
  def run(args) do
    Program.test!(Config.load(), args)
  end
end
