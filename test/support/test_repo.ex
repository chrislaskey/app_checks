defmodule AppChecks.TestRepo do
  @moduledoc """
  A throwaway git repository for the tests that run the program, which
  reads every file and every change from git. `create/2` writes the files,
  commits them and marks the commit as the branch called `base`. Anything
  written after that is what the branch changed.
  """

  @doc "Creates the repository in `dir` with `files`, a map of path to contents, committed."
  def create(dir, files) do
    File.mkdir_p!(dir)
    git(dir, ["init", "-q"])
    for {path, contents} <- files, do: write(dir, path, contents)
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "first"])
    git(dir, ["branch", "base"])
    dir
  end

  @doc "Writes a file, creating its directory."
  def write(dir, path, contents) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
    full
  end

  @doc "Commits everything."
  def commit(dir, message \\ "change") do
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", message])
  end

  defp git(dir, args) do
    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    :ok
  end
end
