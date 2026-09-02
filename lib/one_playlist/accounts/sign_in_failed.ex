defmodule OnePlaylist.Accounts.SignInFailed do
  @moduledoc """
  Establishing a session with Supabase Auth did not succeed.

  A **domain** error rather than infrastructure, because the overwhelmingly
  common cause is a person mistyping their password — that is the system working
  as designed, not something being down, and retrying it automatically would be
  wrong.

  ## The reasons are deliberately coarse at the boundary

  `:invalid_credentials` covers both "no such account" and "wrong password", and
  that conflation is the point: distinguishing them tells an attacker which
  email addresses have accounts here. GoTrue itself answers both with the same
  `400 invalid_credentials`, and this type preserves that rather than helpfully
  unpacking it.

  The reasons that *are* separated are the ones a user can act on differently:
  an unconfirmed email needs the mail resending, a weak password needs a
  different password, and rate limiting needs waiting.

  `:link_expired` is coarse for the same reason `:invalid_credentials` is. It
  covers a magic link that has expired, one already used, a six-digit code that
  is wrong, and an OAuth exchange whose flow state GoTrue no longer holds —
  GoTrue itself answers a wrong code and an expired one with the same
  `otp_expired`, and every one of them has the same remedy: start again.
  """

  use Errata.Error,
    default_message: "could not sign you in",
    default_reason: :invalid_credentials,
    reasons: [
      :invalid_credentials,
      :email_not_confirmed,
      :weak_password,
      :rate_limited,
      :signups_disabled,
      :already_registered,
      :link_expired
    ],
    code: "SIGN_IN_FAILED"

  def http_status(%{reason: :rate_limited}), do: 429
  def http_status(_error), do: 401
end
