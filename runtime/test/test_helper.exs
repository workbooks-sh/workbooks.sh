ExUnit.start()

# NOTE: We deliberately do NOT start the full OTP application here.
# `Workbooks.Application` binds network ports (Bandit/control-plane), which
# would make `mix test` flaky and refuse to run in parallel / CI.
#
# Tests that need a running service should start only that service in a
# per-module `setup` (or `setup_all`) block, e.g.:
#
#     setup do
#       {:ok, _pid} = Workbooks.OQL.start_link(nil)
#       :ok
#     end
#
# Pure-function modules (like Workbooks.CommandRegistry.list/0) need no setup.
