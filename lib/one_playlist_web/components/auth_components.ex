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

  ## The two other ways in

  `magic_link_action` adds a second submit button to the **same** form, pointed
  at a different URL with `formaction`. One email field serves both buttons,
  which is the whole reason for doing it this way rather than with a second
  form: nobody types their address twice. `formnovalidate` is what lets the
  button submit with the password field empty — without it the browser refuses
  to send a form whose `required` password is blank, which is the normal state
  of affairs for somebody who wants a link precisely because they have no
  password. The cost is that a password typed and then abandoned travels with
  the request; the receiving action ignores it.

  `google_action` renders a separate one-button form. Separate because it posts
  nothing the user typed, and a form because starting an OAuth flow by `GET`
  would let any page — or a browser prefetching links — begin one on the user's
  behalf. A `POST` carries the CSRF token.
  """
  attr :action, :string, required: true
  attr :submit_label, :string, required: true
  attr :password_autocomplete, :string, values: ~w(current-password new-password), required: true
  attr :email, :string, default: nil
  attr :error_message, :string, default: nil
  attr :configured?, :boolean, default: true
  attr :magic_link_action, :string, default: nil, doc: "when set, offers to email a link instead"
  attr :google_action, :string, default: nil, doc: "when set, offers to continue with Google"
  slot :footer, required: true

  def credentials_form(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm w-full">
      <.not_configured :if={not @configured?} />
      <.auth_error :if={@error_message} message={@error_message} />

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

        <button
          :if={@magic_link_action}
          type="submit"
          formaction={@magic_link_action}
          formnovalidate
          disabled={not @configured?}
          class="btn btn-ghost w-full"
          id="magic-link"
        >
          <.icon name="hero-envelope" class="w-4 h-4" /> Email me a sign-in link instead
        </button>
      </.form>

      <div :if={@google_action}>
        <div class="divider text-xs opacity-70">or</div>
        <.form for={%{}} action={@google_action}>
          <button
            type="submit"
            disabled={not @configured?}
            class="btn btn-outline w-full"
            id="continue-with-google"
          >
            Continue with Google
          </button>
        </.form>
      </div>

      <p class="text-sm text-center mt-6 opacity-70">
        {render_slot(@footer)}
      </p>
    </div>
    """
  end

  @doc """
  The six-digit code form, shown once a sign-in email has been sent.

  The address travels in a hidden field because GoTrue verifies a code
  *against an address* — the code alone names nothing — and asking the person to
  type it a second time is the one thing this page must not do.

  `autocomplete="one-time-code"` is what lets a phone or password manager offer
  the code straight from the email, and `inputmode="numeric"` is what brings up
  a number pad on a touch keyboard. Both are the difference between a form that
  is merely correct and one that is pleasant on the device a person is most
  likely to be reading their email on.
  """
  attr :action, :string, required: true
  attr :email, :string, required: true
  attr :error_message, :string, default: nil

  def code_form(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm w-full">
      <.auth_error :if={@error_message} message={@error_message} />

      <.form :let={f} for={%{}} as={:code} action={@action} class="space-y-4">
        <input type="hidden" name={f[:email].name} value={@email} />

        <.input
          field={f[:token]}
          type="text"
          label="Six-digit code"
          value={nil}
          inputmode="numeric"
          autocomplete="one-time-code"
          pattern="[0-9]{6}"
          maxlength="6"
          required
          autofocus
        />

        <button type="submit" class="btn btn-primary w-full">Sign in with the code</button>
      </.form>
    </div>
    """
  end

  defp not_configured(assigns) do
    ~H"""
    <div class="alert alert-warning mb-6" id="auth-not-configured" role="alert">
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
    """
  end

  attr :message, :string, required: true

  defp auth_error(assigns) do
    ~H"""
    <div class="alert alert-error mb-6" id="auth-error" role="alert">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
      <span>{@message}</span>
    </div>
    """
  end
end
