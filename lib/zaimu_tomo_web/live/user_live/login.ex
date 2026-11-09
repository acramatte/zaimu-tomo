defmodule ZaimuTomoWeb.UserLive.Login do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={:bare}>
      <main class="login-shell">
        <.auth_stage />

        <section class="auth-desk">
          <div class="slip-wrap">
            <div class="slip">
              <header class="slip-head">
                <p class="slip-kicker">Zaimutomo · Personal books</p>
                <h1 class="slip-title">
                  <%= if @current_scope do %>
                    Confirm it's you
                  <% else %>
                    Sign-in slip
                  <% end %>
                </h1>
                <p class="slip-meta">
                  <span>No. {@today
                  |> Date.day_of_year()
                  |> Integer.to_string()
                  |> String.pad_leading(4, "0")}</span>
                  <span>{Calendar.strftime(@today, "%d.%m.%Y")}</span>
                </p>
              </header>

              <p :if={@current_scope} class="slip-note">
                You need to reauthenticate to perform sensitive actions on your account.
              </p>

              <div class="slip-methods" role="tablist" aria-label="Sign-in method">
                <span class="slip-label">Method</span>
                <button
                  id="method-password"
                  type="button"
                  role="tab"
                  aria-selected="true"
                  phx-click={switch_method(:password)}
                >
                  Password
                </button>
                <button
                  id="method-magic"
                  type="button"
                  role="tab"
                  aria-selected="false"
                  phx-click={switch_method(:magic)}
                >
                  Email link
                </button>
              </div>

              <.form
                :let={f}
                for={@form}
                id="login_form_password"
                action={~p"/users/log-in"}
                phx-submit="submit_password"
                phx-trigger-action={@trigger_submit}
                class="slip-form"
              >
                <.input
                  readonly={!!@current_scope}
                  field={f[:email]}
                  type="email"
                  label="Email"
                  autocomplete="email"
                  required
                  class="slip-input"
                  phx-mounted={!@current_scope && JS.focus()}
                />
                <.input
                  field={@form[:password]}
                  type="password"
                  label="Password"
                  autocomplete="current-password"
                  class="slip-input"
                />
                <.input field={f[:remember_me]} type="checkbox" label="Keep me signed in" />

                <button class="slip-submit" phx-disable-with="Stamping…">
                  <span>Sign in</span>
                  <.icon name="hero-arrow-right" class="size-5 slip-arrow" />
                </button>
                <button type="button" class="slip-link" phx-click={switch_method(:magic)}>
                  Forgot it? Get an email link instead.
                </button>
              </.form>

              <.form
                :let={f}
                for={@form}
                id="login_form_magic"
                action={~p"/users/log-in"}
                phx-submit="submit_magic"
                class="slip-form hidden"
              >
                <.input
                  readonly={!!@current_scope}
                  field={f[:email]}
                  type="email"
                  label="Email"
                  autocomplete="email"
                  required
                  class="slip-input"
                />
                <p class="slip-hint">
                  One-time link, valid for a few minutes. No password to remember.
                </p>
                <button class="slip-submit" phx-disable-with="Sending…">
                  <span>Log in with email</span>
                  <.icon name="hero-paper-airplane" class="size-5 slip-arrow" />
                </button>
              </.form>

              <p :if={local_mail_adapter?()} class="slip-dev">
                Dev mail adapter · sent mail lands in <.link href="/dev/mailbox">/dev/mailbox</.link>
              </p>

              <div class="slip-stamp" aria-hidden="true">
                <span>Verified</span>
                <span class="kanji">友</span>
              </div>
            </div>
          </div>

          <p :if={!@current_scope} class="auth-signup">
            No account yet?
            <.link navigate={~p"/users/register"}>Sign up <span aria-hidden="true">→</span></.link>
          </p>
        </section>
      </main>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       today: Date.utc_today()
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp switch_method(method) do
    {show, hide} = if method == :password, do: {"password", "magic"}, else: {"magic", "password"}

    JS.hide(to: "#login_form_#{hide}")
    |> JS.show(
      to: "#login_form_#{show}",
      transition: {"login-enter", "login-enter-from", "login-enter-to"},
      time: 220
    )
    |> JS.set_attribute({"aria-selected", "true"}, to: "#method-#{show}")
    |> JS.set_attribute({"aria-selected", "false"}, to: "#method-#{hide}")
    |> JS.focus_first(to: "#login_form_#{show}")
  end

  defp local_mail_adapter? do
    Application.get_env(:zaimu_tomo, ZaimuTomo.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
