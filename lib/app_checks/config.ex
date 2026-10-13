defmodule AppChecks.Config do
  @moduledoc """
  Reads `.app_checks.exs`, the configuration in the project root.

  The file is a map in the shape of `.credo.exs`: named configs, each a
  complete list of which checks run and what a violation means.

      %{
        custom_checks: "priv/checks",
        configs: [
          %{
            name: "default",
            base_ref: "main",
            checks: [
              enabled: [
                :no_io_inspect,
                {:core_component_tags, config: [paths: ["lib/my_app_web/components/core_components.ex"]]},
                {:architect_review, level: :warning, scope: :changed, config: [paths: ["config/**"]]}
              ],
              disabled: [:human_review]
            ]
          }
        ]
      }

  `custom_checks` is the directory of the project's own checks, one `.rs`
  file each, compiled in with the built-in ones. It is one directory for
  the whole file, since it decides what gets built.

  `mix app_checks` runs the config named `"default"`. `--config-name NAME`
  runs another. Configs do not merge: each one is the whole list for its
  run. In a config, `base_ref` is the git ref the branch is compared with,
  `"main"` when left out. Under `checks`, `enabled` lists the checks that
  run, in order, and `disabled` the checks the project knows about and
  chose not to run. A check in neither list does not run either, and the
  summary counts it, so a new check is not silently ignored.

  An enabled check is an atom, or a tuple with options: `level`, `:error`
  or `:warning`, is what a violation means and defaults to `:error`;
  `scope`, `:all` or `:changed`, is which files the check looks at and
  defaults to `:all`; `config` holds the check's own keys. A check given
  twice, or both enabled and disabled, is an error.

  `load/1` returns the file as a map with every default filled in. The
  program itself never sees named configs: `AppChecks.Program` turns the
  chosen one into flags.
  """

  @file_name ".app_checks.exs"
  @default_custom_checks "priv/checks"
  @default_base_ref "main"
  @levels [:error, :warning]
  @scopes [:all, :changed]
  @top_keys [:custom_checks, :configs]
  @config_keys [:name, :base_ref, :checks]
  @check_keys [:enabled, :disabled]
  @entry_keys [:level, :scope, :config]

  @doc "The file in the project root, `#{@file_name}`."
  def file_name, do: @file_name

  @doc "The levels a violation can have."
  def levels, do: @levels

  @doc "The scopes a check can have."
  def scopes, do: @scopes

  @doc """
  What `load/1` returns when there is no file: the default custom checks
  directory and one empty config called `"default"`.
  """
  def defaults do
    %{
      custom_checks: @default_custom_checks,
      configs: [%{name: "default", base_ref: @default_base_ref, enabled: [], disabled: []}]
    }
  end

  @doc """
  Reads the file at `path`, `#{@file_name}` by default, filling in every
  default. A missing file means `defaults/0`. Raises `Mix.Error` naming
  the key when the file has the wrong shape.
  """
  def load(path \\ @file_name) do
    if File.exists?(path) do
      {contents, _bindings} = Code.eval_file(path)
      normalize!(contents, path)
    else
      defaults()
    end
  end

  @doc """
  The config called `name` in a loaded config. Raises `Mix.Error` naming
  the configs there are when there is none.
  """
  def named(%{configs: configs}, name) do
    Enum.find(configs, &(&1.name == name)) ||
      Mix.raise(
        "there is no config called #{inspect(name)} in #{@file_name}; the configs are: " <>
          Enum.map_join(configs, ", ", &inspect(&1.name))
      )
  end

  @doc """
  A check's `config` keyword list as `key=value` strings, in order. A list
  gives the key once per element and a nested keyword list adds a segment
  to the key:

      iex> AppChecks.Config.flatten(
      ...>   default: :high, groups: [agents: ["AGENTS.md"]], paths: ["config/**", "mix.exs"]
      ...> )
      ["default=high", "groups.agents=AGENTS.md", "paths=config/**", "paths=mix.exs"]

  """
  def flatten(config) do
    Enum.flat_map(config, fn {key, value} -> flatten(to_string(key), value) end)
  end

  defp flatten(prefix, value) when is_list(value) do
    if Keyword.keyword?(value) and value != [] do
      Enum.flat_map(value, fn {key, inner} -> flatten("#{prefix}.#{key}", inner) end)
    else
      Enum.flat_map(value, &flatten(prefix, &1))
    end
  end

  defp flatten(prefix, value), do: ["#{prefix}=#{value}"]

  defp normalize!(contents, path) do
    unless is_map(contents) do
      Mix.raise("#{path} must be a map with a configs key, see `mix help app_checks`")
    end

    only_keys!(contents, @top_keys, path, "the file")

    custom_checks = Map.get(contents, :custom_checks, @default_custom_checks)

    unless is_binary(custom_checks) do
      Mix.raise("#{path}: custom_checks must be a string, got #{inspect(custom_checks)}")
    end

    configs = Map.get(contents, :configs, [])

    unless is_list(configs) and configs != [] do
      Mix.raise(
        "#{path}: configs must be a list with at least one config, got #{inspect(configs)}"
      )
    end

    configs = Enum.map(configs, &normalize_config!(&1, path))

    names = Enum.map(configs, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [name | _] -> Mix.raise("#{path}: two configs are called #{inspect(name)}")
    end

    %{custom_checks: custom_checks, configs: configs}
  end

  defp normalize_config!(config, path) do
    unless is_map(config) do
      Mix.raise("#{path}: each config must be a map, got #{inspect(config)}")
    end

    name = Map.get(config, :name)

    unless is_binary(name) and name != "" do
      Mix.raise("#{path}: a config needs a name, a string, got #{inspect(name)}")
    end

    where = "the config #{inspect(name)}"
    only_keys!(config, @config_keys, path, where)

    base_ref = Map.get(config, :base_ref, @default_base_ref)

    unless is_binary(base_ref) and base_ref != "" do
      Mix.raise("#{path}: #{where}: base_ref must be a git ref, got #{inspect(base_ref)}")
    end

    checks = Map.get(config, :checks, [])

    unless Keyword.keyword?(checks) do
      Mix.raise("#{path}: #{where}: checks must be a keyword list, got #{inspect(checks)}")
    end

    only_keys!(checks, @check_keys, path, "#{where}, under checks")

    enabled = Enum.map(list!(checks, :enabled, path, where), &normalize_entry!(&1, path, where))
    disabled = list!(checks, :disabled, path, where)

    for name <- disabled, not is_atom(name) do
      Mix.raise("#{path}: #{where}: disabled must list check names, got #{inspect(name)}")
    end

    enabled_names = Enum.map(enabled, & &1.name)

    case enabled_names -- Enum.uniq(enabled_names) do
      [] -> :ok
      [name | _] -> Mix.raise("#{path}: #{where}: #{name} is enabled twice")
    end

    case Enum.filter(disabled, &(&1 in enabled_names)) do
      [] -> :ok
      [name | _] -> Mix.raise("#{path}: #{where}: #{name} is both enabled and disabled")
    end

    %{name: name, base_ref: base_ref, enabled: enabled, disabled: disabled}
  end

  defp normalize_entry!(name, _path, _where) when is_atom(name) do
    %{name: name, level: :error, scope: :all, config: []}
  end

  defp normalize_entry!({name, opts}, path, where) when is_atom(name) do
    unless Keyword.keyword?(opts) do
      Mix.raise(
        "#{path}: #{where}: the options of #{name} must be a keyword list, got #{inspect(opts)}"
      )
    end

    only_keys!(opts, @entry_keys, path, "#{where}, for #{name}")

    level = Keyword.get(opts, :level, :error)
    scope = Keyword.get(opts, :scope, :all)
    config = Keyword.get(opts, :config, [])

    unless level in @levels do
      Mix.raise(
        "#{path}: #{where}: level of #{name} must be one of #{inspect(@levels)}, got #{inspect(level)}"
      )
    end

    unless scope in @scopes do
      Mix.raise(
        "#{path}: #{where}: scope of #{name} must be one of #{inspect(@scopes)}, got #{inspect(scope)}"
      )
    end

    unless Keyword.keyword?(config) do
      Mix.raise(
        "#{path}: #{where}: config of #{name} must be a keyword list, got #{inspect(config)}"
      )
    end

    %{name: name, level: level, scope: scope, config: config}
  end

  defp normalize_entry!(entry, path, where) do
    Mix.raise(
      "#{path}: #{where}: an enabled check is a name or a {name, options} tuple, got #{inspect(entry)}"
    )
  end

  defp list!(checks, key, path, where) do
    case Keyword.get(checks, key, []) do
      list when is_list(list) -> list
      other -> Mix.raise("#{path}: #{where}: #{key} must be a list, got #{inspect(other)}")
    end
  end

  defp only_keys!(map_or_keyword, allowed, path, where) do
    keys = map_or_keyword |> Enum.map(fn {key, _} -> key end)

    case keys -- allowed do
      [] ->
        :ok

      [key | _] ->
        Mix.raise(
          "#{path}: #{where} has an unknown key #{inspect(key)}; the keys are #{inspect(allowed)}"
        )
    end
  end
end
