defmodule AppChecks.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :app_checks,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # Files the tests read but do not run, such as a components module
      test_ignore_filters: [~r"^test/fixtures/"],
      description: description(),
      package: package()
    ]
  end

  def application do
    []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Only for `mix app_checks.install`. A project without igniter can
      # still run the checks, see the README for the manual steps.
      {:igniter, "~> 0.6", optional: true}
    ]
  end

  defp description do
    "Fast custom checks for an Elixir project, written in Rust and run as one Mix task"
  end

  defp package do
    [
      # The Rust crate ships with the package. It is built into the project's
      # _build directory, never inside the dependency.
      files: ~w(lib priv/checks/Cargo.toml priv/checks/Cargo.lock priv/checks/build.rs
                priv/checks/src mix.exs README.md .formatter.exs)
    ]
  end
end
