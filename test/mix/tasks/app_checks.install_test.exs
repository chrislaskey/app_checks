defmodule Mix.Tasks.AppChecks.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @mix_exs """
  defmodule Test.MixProject do
    use Mix.Project

    def project do
      [app: :test, version: "0.1.0", deps: deps()]
    end

    defp deps do
      [
        {:app_checks, "~> 0.1"},
        {:ex_check, "~> 0.17", only: [:dev, :test], runtime: false}
      ]
    end
  end
  """

  @without_ex_check String.replace(
                      @mix_exs,
                      ~s|,\n      {:ex_check, "~> 0.17", only: [:dev, :test], runtime: false}|,
                      ""
                    )

  describe ".app_checks.exs" do
    test "is written with core_component_tags off when there is no components module" do
      igniter = install()

      assert_creates(igniter, ".app_checks.exs")
      content = content(igniter, ".app_checks.exs")
      assert content =~ "disabled: [:core_component_tags]"
      refute content =~ ":core_component_tags,"
      assert content =~ ~s|custom_checks: "priv/checks"|
      assert content =~ ~s|base_ref: "origin/main"|
      assert content =~ "{:separate_pr,"
      assert content =~ "{:architect_review,"
      assert content =~ "{:human_review,"

      # The file it writes is a config the task would accept.
      {config, _} = Code.eval_string(content)
      assert %{configs: [%{name: "default"}]} = config
    end

    test "keeps core_component_tags on when lib has a core_components.ex" do
      igniter =
        install(%{
          "lib/my_app_web/components/core_components.ex" =>
            "defmodule MyAppWeb.CoreComponents do\nend\n"
        })

      content = content(igniter, ".app_checks.exs")
      assert content =~ ":core_component_tags,"
      assert content =~ "disabled: []"
    end

    test "is left alone when it exists" do
      igniter = install(%{".app_checks.exs" => "%{configs: [%{name: \"default\"}]}\n"})

      assert_unchanged(igniter, ".app_checks.exs")
    end
  end

  describe "mix.exs" do
    test "keeps the dependency out of releases" do
      install()
      |> assert_has_patch("mix.exs", """
      - |      {:app_checks, "~> 0.1"},
      + |      {:app_checks, "~> 0.1", only: [:dev, :test], runtime: false},
      """)
    end
  end

  describe ".check.exs" do
    test "gets the tool added to an existing file" do
      install(%{".check.exs" => "[\n  tools: [\n    {:credo, false}\n  ]\n]\n"})
      |> assert_has_patch(".check.exs", """
      + |    {:app_checks, "mix app_checks"}
      """)
    end

    test "gets the tool added when the list comes after other expressions" do
      install(%{
        ".check.exs" =>
          "base = \"\"\n\n[\n  tools: [\n    {:other, \"mix other\" <> base}\n  ]\n]\n"
      })
      |> assert_has_patch(".check.exs", """
      + |    {:app_checks, "mix app_checks"}
      """)
    end

    test "gets a tools key when the file has none" do
      install(%{".check.exs" => "[retry: false]\n"})
      |> assert_has_patch(".check.exs", """
      + |[retry: false, tools: [{:app_checks, "mix app_checks"}]]
      """)
    end

    test "keeps a tool that is already there, however it is configured" do
      igniter =
        install(%{
          ".check.exs" =>
            "[\n  tools: [\n    {:app_checks, \"mix app_checks --base x\"}\n  ]\n]\n"
        })

      assert_unchanged(igniter, ".check.exs")
    end

    test "is created when ex_check is a dependency without one" do
      igniter = install()

      assert_creates(igniter, ".check.exs")
      assert content(igniter, ".check.exs") =~ ~s|{:app_checks, "mix app_checks"}|
    end

    test "is not created without ex_check" do
      igniter = install(%{"mix.exs" => @without_ex_check})

      refute_creates(igniter, ".check.exs")
    end
  end

  describe ".tool-versions" do
    test "gets rust pinned when it exists without it" do
      install(%{".tool-versions" => "elixir 1.19.4-otp-28\n"})
      |> assert_has_patch(".tool-versions", """
      + |rust 1.99.0
      """)
    end

    test "is left alone when rust is pinned" do
      igniter = install(%{".tool-versions" => "rust 1.90.0\n"})

      assert_unchanged(igniter, ".tool-versions")
    end

    test "is not created" do
      refute_creates(install(), ".tool-versions")
    end
  end

  test "says that Rust is needed" do
    assert_has_notice(install(), &String.contains?(&1, "needs Rust"))
  end

  test "changes nothing on a second run" do
    igniter = install() |> apply_igniter!() |> Igniter.compose_task("app_checks.install", [])

    assert_unchanged(igniter)
  end

  defp install(files \\ %{}) do
    test_project(files: Map.merge(%{"mix.exs" => @mix_exs}, files))
    |> Igniter.compose_task("app_checks.install", [])
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end
end
