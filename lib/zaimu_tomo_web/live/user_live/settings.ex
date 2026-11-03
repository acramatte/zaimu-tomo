defmodule ZaimuTomoWeb.UserLive.Settings do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounts
  alias ZaimuTomo.Accounts.Scope

  # Settings always opens; email and password changes, as sensitive actions,
  # stay locked until a recent login (sudo mode).
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div class="settings-page">
      <section class="settings-hero">
        <span class="settings-eyebrow"><i></i> Zaimutomo · Account</span>
        <h1 class="settings-hero-title">Account settings</h1>
        <p class="settings-hero-sub">
          Manage your profile, email address and password settings
        </p>

        <div class="settings-hero-id">
          <div class="settings-avatar" aria-hidden="true">
            {String.slice(@current_scope.user.email, 0, 2) |> String.upcase()}
          </div>
          <div class="settings-hero-text">
            <div class="name">{@current_scope.user.display_name || "Your account"}</div>
            <div class="mail">{@current_scope.user.email}</div>
          </div>
          <div class="settings-hero-chips">
            <span class="settings-chip">
              Base currency <b>{@current_scope.user.base_currency}</b>
            </span>
            <span class={["settings-chip", if(@sudo_mode?, do: "unlocked", else: "locked")]}>
              Session <b>{if @sudo_mode?, do: "Unlocked", else: "Locked"}</b>
            </span>
          </div>
        </div>
      </section>

      <nav class="settings-jump" aria-label="Settings sections">
        <a href="#profile"><span class="n">01</span> Profile</a>
        <a href="#email"><span class="n">02</span> Email</a>
        <a href="#password"><span class="n">03</span> Password</a>
      </nav>

      <div class="settings-panel">
        <!-- Profile -->
        <section class="settings-block" id="profile" aria-labelledby="profile-settings-title">
          <header class="settings-block-head">
            <span class="settings-numeral" aria-hidden="true">01</span>
            <div class="text">
              <h2 id="profile-settings-title" class="settings-block-title">Profile</h2>
              <p class="settings-block-sub">
                How you appear in Zaimutomo and your primary currency
              </p>
            </div>
          </header>

          <.form
            for={@profile_form}
            id="profile_form"
            phx-submit="update_profile"
            phx-change="validate_profile"
          >
            <div class="settings-fields">
              <div class="settings-field">
                <.input
                  field={@profile_form[:display_name]}
                  type="text"
                  label="Display name"
                  placeholder="How you'd like to be addressed"
                  autocomplete="name"
                  aria-describedby="display-name-hint"
                />
                <p class="settings-hint" id="display-name-hint">
                  Optional. Shown in the sidebar and across your books.
                </p>
              </div>

              <div class="settings-field">
                <.input
                  field={@profile_form[:base_currency]}
                  type="text"
                  label="Base currency"
                  placeholder="EUR"
                  maxlength="3"
                  required
                  aria-describedby="base-currency-hint"
                />
                <p class="settings-hint" id="base-currency-hint">
                  Three-letter ISO 4217 code, for example CHF or EUR. Used as the default
                  currency for amounts and reports.
                </p>
              </div>
            </div>

            <div class="settings-actions">
              <.button class="settings-action" phx-disable-with="Saving...">Save Profile</.button>
            </div>
          </.form>
        </section>

        <!-- Email -->
        <section class="settings-block" id="email" aria-labelledby="email-settings-title">
          <header class="settings-block-head">
            <span class="settings-numeral" aria-hidden="true">02</span>
            <div class="text">
              <h2 id="email-settings-title" class="settings-block-title">Email</h2>
              <p class="settings-block-sub">Used to sign in and receive notifications</p>
            </div>
          </header>

          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
          >
            <div class="settings-fields">
              <div class="settings-field">
                <.input
                  field={@email_form[:email]}
                  type="email"
                  label="Email"
                  autocomplete="username"
                  readonly={!@sudo_mode?}
                  required
                  aria-describedby="email-hint"
                />
                <p class="settings-hint" id="email-hint">
                  We'll email a confirmation link to the new address; the change applies once
                  you confirm it.
                </p>
              </div>
            </div>

            <div :if={@sudo_mode?} class="settings-actions">
              <.button
                id="email-submit"
                class="settings-action"
                phx-disable-with="Changing..."
              >
                Change Email
              </.button>
            </div>

            <div :if={!@sudo_mode?} class="settings-locked" id="email-locked">
              <span class="settings-locked-icon" aria-hidden="true">
                <.icon name="hero-lock-closed" class="size-4" />
              </span>
              <div>
                <div class="h">Locked for this session</div>
                <p>For your safety, changing your email needs a fresh login.</p>
                <.button id="email-reauth" class="settings-action-ghost" href={~p"/users/log-in"}>
                  <.icon name="hero-finger-print" class="size-4" /> Log in again to change
                </.button>
              </div>
            </div>
          </.form>
        </section>

        <!-- Password -->
        <section class="settings-block" id="password" aria-labelledby="password-settings-title">
          <header class="settings-block-head">
            <span class="settings-numeral" aria-hidden="true">03</span>
            <div class="text">
              <h2 id="password-settings-title" class="settings-block-title">Password</h2>
              <p class="settings-block-sub">
                Set or update the password used for this account
              </p>
            </div>
          </header>

          <div :if={!@sudo_mode?} class="settings-locked" id="password-locked">
            <span class="settings-locked-icon" aria-hidden="true">
              <.icon name="hero-lock-closed" class="size-4" />
            </span>
            <div>
              <div class="h">Locked for this session</div>
              <p>For your safety, changing your password needs a fresh login.</p>
              <.button id="password-reauth" class="settings-action-ghost" href={~p"/users/log-in"}>
                <.icon name="hero-finger-print" class="size-4" /> Confirm it's you
              </.button>
            </div>
          </div>

          <.form
            :if={@sudo_mode?}
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              autocomplete="username"
              value={@current_email}
            />

            <div class="settings-fields">
              <div class="settings-field">
                <.input
                  field={@password_form[:password]}
                  type="password"
                  label="New password"
                  autocomplete="new-password"
                  required
                  aria-describedby="new-password-hint"
                />
                <p class="settings-hint" id="new-password-hint">
                  At least 12 characters. You'll stay signed in on this device.
                </p>
              </div>

              <div class="settings-field">
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  label="Confirm new password"
                  autocomplete="new-password"
                />
              </div>
            </div>

            <div class="settings-actions">
              <.button class="settings-action" phx-disable-with="Saving...">Save Password</.button>
            </div>
          </.form>
        </section>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)
    profile_changeset = Accounts.change_user_profile(user)

    socket =
      socket
      |> assign(:page_title, "Account settings")
      |> assign(:current_path, "/users/settings")
      |> assign(:current_email, user.email)
      |> assign(:sudo_mode?, Accounts.sudo_mode?(user))
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_profile", params, socket) do
    %{"user" => user_params} = params

    profile_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_profile(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, profile_form: profile_form)}
  end

  def handle_event("update_profile", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    case Accounts.update_user_profile(user, user_params) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:current_scope, Scope.for_user(user))
          |> assign(:profile_form, to_form(Accounts.change_user_profile(user)))
          |> put_flash(:info, "Profile updated successfully.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    with :ok <- check_sudo_mode(user),
         %{valid?: true} = changeset <- Accounts.change_user_email(user, user_params) do
      Accounts.deliver_user_update_email_instructions(
        Ecto.Changeset.apply_action!(changeset, :insert),
        user.email,
        &url(~p"/users/settings/confirm-email/#{&1}")
      )

      info = "A link to confirm your email change has been sent to the new address."
      {:noreply, socket |> put_flash(:info, info)}
    else
      :reauthenticate -> {:noreply, reauthenticate(socket)}
      changeset -> {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    with :ok <- check_sudo_mode(user),
         %{valid?: true} = changeset <- Accounts.change_user_password(user, user_params) do
      {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}
    else
      :reauthenticate -> {:noreply, reauthenticate(socket)}
      changeset -> {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  # The page can stay open past the sudo window, so check again on every sensitive submit.
  defp check_sudo_mode(user) do
    if Accounts.sudo_mode?(user), do: :ok, else: :reauthenticate
  end

  # The log-in page sends an already signed-in user back to settings.
  defp reauthenticate(socket) do
    socket
    |> put_flash(:error, "Log in again to change your email or password.")
    |> redirect(to: ~p"/users/log-in")
  end
end
