defmodule AshIntegration.Transport.SigningScheme do
  @moduledoc """
  The `signing` union — an explicit, tagged choice of signing scheme on the
  transport config, mirroring the `auth` union. The variant *is* the answer to
  "does this connection sign, and how"; there is no implicit secret-present switch.

    * `none`   — unsigned (default)
    * `stripe` — native built-in (`AshIntegration.Transport.Signing.Stripe`)
    * `custom` — staged Lua behaviour (`AshIntegration.Transport.Signing.Custom`)
  """
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        none: [
          type: AshIntegration.Transport.Signing.None,
          tag: :type,
          tag_value: "none"
        ],
        stripe: [
          type: AshIntegration.Transport.Signing.Stripe,
          tag: :type,
          tag_value: "stripe"
        ],
        custom: [
          type: AshIntegration.Transport.Signing.Custom,
          tag: :type,
          tag_value: "custom"
        ]
      ],
      storage: :map_with_tag
    ]
end
