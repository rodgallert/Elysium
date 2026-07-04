module Statusable
  extend ActiveSupport::Concern
  included do
    enum :status, {
      pending: 'pending',
      active: 'active',
      suspended: 'suspended',
      blocked: 'blocked',
      deleted: 'deleted',
      pending_deletion: 'pending_deletion'
    }
  end
end