defmodule OnePlaylistWeb.AuthComponents do
  @moduledoc """
  The email-and-password form, shared by signing in and signing up.

  The two pages differ in their heading, their button, the link underneath, and
  one `autocomplete` value. Everything else — the layout, the error alert, the
  not-configured notice, the field names the controllers pattern-match on — is
  the same, and was worth writing once.

  That last item is the reason this is a component rather than two templates
  that happen to look alike: both controllers match on
  `%{"user" => %{"email" => _, "password" => _}}`, so the input names are part
  of a contract between this markup and two modules. One definition means they
  cannot drift apart.
  """

  use OnePlaylistWeb, :html

  @doc """
  The credentials form.

  `autocomplete` is not cosmetic. `current-password` tells a password manager to
  offer a saved credential; `new-password` tells it to offer to generate one and
  stops it filling the sign-up form with the wrong entry. Getting this wrong is
  a real usability failure that looks like a browser bug.
  """
  attr :action, :string, required: true
  attr :submit_label, :string, required: true
  attr :password_autocomplete, :string, values: ~w(current-password new-password), required: true
  attr :email, :string, default: nil
  attr :error_message, :string, default: nil
  attr :configured?, :boolean, default: true
  slot :footer, required: true

  def credentials_form(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm w-full">
      <div
        :if={not @configured?}
        class="alert alert-warning mb-6"
        id="auth-not-configured"
        role="alert"
      >
        <.icon name="hero-wrench-screwdriver" class="w-5 h-5 shrink-0" />
        <div>
          <p class="font-semibold">Sign-in is not configured on this server.</p>
          <p class="text-sm">
            Copy <code>config/dev_local.example.exs</code>
            to <code>config/dev_local.exs</code>
            and fill in the values printed by <code>supabase status</code>.
          </p>
        </div>
      </div>

      <div :if={@error_message} class="alert alert-error mb-6" id="auth-error" role="alert">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
        <span>{@error_message}</span>
      </div>

      <.form :let={f} for={%{}} as={:user} action={@action} class="space-y-4">
        <.input
          field={f[:email]}
          type="email"
          label="Email"
          value={@email}
          autocomplete="username"
          required
          autofocus
        />

        <%!-- `value={nil}` so a re-rendered form after a failed attempt never
              echoes the password back into the DOM. --%>
        <.input
          field={f[:password]}
          type="password"
          label="Password"
          value={nil}
          autocomplete={@password_autocomplete}
          required
        />

        <button type="submit" disabled={not @configured?} class="btn btn-primary w-full">
          {@submit_label}
        </button>
      </.form>

      <p class="text-sm text-center mt-6 opacity-70">
        {render_slot(@footer)}
      </p>
    </div>
    """
  end
end
