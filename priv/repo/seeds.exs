# Script for populating the development database. You can run it as:
#
#     mix run priv/repo/seeds.exs

%{user: user, accounts: accounts} = ZaimuTomo.DevSeeds.seed!()
%{email: email, password: password} = ZaimuTomo.DevSeeds.demo_credentials()

IO.puts("Seeded #{length(accounts)} financial accounts for #{user.display_name}.")
IO.puts("Log in with #{email} / #{password}")
