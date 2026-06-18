defmodule Nexus.Audit do
  @moduledoc "Capability audit — delegates to `WorkCore.Audit` (the toolchain home). See it for docs."
  defdelegate unit(node), to: WorkCore.Audit
  defdelegate workbook(root), to: WorkCore.Audit
  defdelegate granted(node), to: WorkCore.Audit
end
