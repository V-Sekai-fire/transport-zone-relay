defmodule Mix.Tasks.Compile.ZoneNif do
  @moduledoc "Builds `priv/native/libzone_nif.so` when a Mojo source is newer than it."
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    so = "priv/native/libzone_nif.so"
    srcs = Path.wildcard("native/*.mojo") ++ ["scripts/build-nif.sh"]

    stale? =
      not File.exists?(so) or
        Enum.any?(srcs, fn s -> File.stat!(s, time: :posix).mtime > File.stat!(so, time: :posix).mtime end)

    if stale? do
      case System.cmd("bash", ["scripts/build-nif.sh"], stderr_to_stdout: true) do
        {_, 0} -> {:ok, []}
        {out, _} ->
          Mix.shell().error("mojo build failed:\n" <> out)

          {:error,
           [
             %Mix.Task.Compiler.Diagnostic{
               compiler_name: "zone_nif",
               file: Path.absname("native/zone_nif.mojo"),
               position: nil,
               message: "mojo build failed:\n" <> out,
               severity: :error
             }
           ]}
      end
    else
      {:noop, []}
    end
  end
end
