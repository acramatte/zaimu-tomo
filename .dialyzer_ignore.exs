# Known, verified-benign Dialyzer findings. Each entry below was individually
# investigated — see the commit that added it — not blanket-suppressed.
# Re-check with `mix dialyzer --format ignore_file_strict` after any Ecto,
# Elixir, or OTP upgrade: these rely on specific success-typing limitations
# that a newer version could narrow or fix outright.
[
  # Ecto.Multi wraps a MapSet, itself an opaque type. Dialyzer can't verify a
  # built %Ecto.Multi{} still satisfies that opaqueness once passed back into
  # Multi.insert/3, Multi.update/3, etc. Widely reported Dialyzer/Ecto.Multi
  # limitation, not a real type error — every one of these is a normal
  # Multi.new() |> Multi.insert(...) |> ... pipeline.
  {"lib/zaimu_tomo/accounting.ex", "Type mismatch in call without opaque term in insert."},
  {"lib/zaimu_tomo/accounting.ex", "Type mismatch in call without opaque term in update."},
  {"lib/zaimu_tomo/documents.ex", "Type mismatch in call without opaque term in insert."},
  {"lib/zaimu_tomo/financial_accounts.ex",
   "Type mismatch in call without opaque term in insert."},
  {"lib/zaimu_tomo/review.ex", "Type mismatch in call without opaque term in run."},

  # storage/s3.ex: File.stream!/2's documented success typing for its modes
  # argument doesn't include :write/:binary, so Dialyzer infers the call in
  # get_object/3 can never succeed, then treats get_result/2 (which only that
  # call feeds) as dead code as a direct consequence. Verified this is a
  # Dialyzer/stdlib precision gap, not a real bug: `File.stream!(path,
  # [:write, :binary])` genuinely works at runtime (modes pass through to
  # :file.open/2, which accepts a broader set than File.stream!/2's @spec
  # documents) — checked directly in iex before adding this entry.
  {"lib/zaimu_tomo/storage/s3.ex", "Function get_result/2 will never be called."},
  {"lib/zaimu_tomo/storage/s3.ex", "The function call stream! will not succeed."}
]
