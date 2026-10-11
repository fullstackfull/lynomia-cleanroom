# A named set of capabilities an account defines and attaches to one of its members
# (docs/p-final/clean-room/specs/C-account-role-permissions.md).
#
# Chatwoot gives a membership one of two roles, agent or administrator, and Lynomia has capabilities that fit
# neither: acting on a store order is a commercial action with money attached, and seeing every support case in
# the account is what a support lead does. Handing out account administration to get either would be worse than
# the problem.
#
# The capability list is a plain array on the row, which the `permissions` text[] column already expresses. No
# join table, no capability registry, no permission object: the published vocabulary plus validation is all that
# any caller needs (package C §9).
#
# PERMISSIONS is the closed vocabulary. It is closed on purpose: a free-text column would let an account invent
# a capability name that some future check happened to honour. It is also the constant
# `spec/factories/custom_roles.rb` and `custom/app/policies/support/ticket_policy.rb` name.
class CustomRole < ApplicationRecord
  # The same identifiers the client publishes in app/javascript/dashboard/constants/permissions.js, in the same
  # order, plus one the client no longer offers.
  PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
    contact_manage
    report_manage
    commerce_order_manage
    support_ticket_manage
    knowledge_base_manage
  ].freeze

  # Lynomia publishes its own documentation and a workspace has no knowledge base, so the client stopped
  # offering this one. It stays acceptable here because roles created before that change still carry it, and
  # dropping it from the validation would make those rows unsaveable -- and because global search still consults
  # it to reach a workspace's frozen pages (app/javascript/dashboard/constants/permissions.js:36).
  RETIRED_PERMISSIONS = %w[knowledge_base_manage].freeze

  belongs_to :account

  # Nullify, never destroy. Deleting a role must lose no membership: each affected member simply has no role
  # afterwards and reverts to the capabilities its built-in role gives it (package C §6). There is no foreign
  # key on `account_users.custom_role_id`, so this association is the only thing that clears the attachment.
  has_many :account_users, dependent: :nullify

  validates :name, presence: true
  # The client requires at least one capability before it will submit (CustomRoleModal.vue:48), and a set that
  # grants nothing is a set somebody will later wonder about, so the server says the same thing.
  validates :permissions, presence: true
  validate :permissions_are_published

  private

  # Reported as one error naming every unknown value, so a client sending two typos learns about both.
  def permissions_are_published
    unknown = permissions.to_a.map(&:to_s) - PERMISSIONS
    return if unknown.empty?

    errors.add(:permissions, I18n.t('errors.custom_roles.unknown_permissions', permissions: unknown.sort.join(', ')))
  end
end
