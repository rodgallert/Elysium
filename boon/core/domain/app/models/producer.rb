require "cpf_cnpj"

class Producer < ApplicationRecord
  include Statusable
  has_secure_password

  before_validation { self.email = email.downcase.strip if email.present? }
  before_validation :normalize_document

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true
  validates :password, presence: true, length: { minimum: 6 }, if: :password_digest_changed?
  validates :document, presence: true, uniqueness: true
  validate :document_must_be_valid_cpf_cnpj
  validates :phone, presence: true
  validates :street, presence: true
  validates :number, presence: true
  validates :city, presence: true
  validates :state, presence: true
  validates :zip_code, presence: true
  validates :birth_date, presence: true

  private

  def normalize_document
    return if document.blank?

    parsed_document = CpfCnpj.which(document)
    self.document = parsed_document ? parsed_document.stripped : document.strip
  end

  def document_must_be_valid_cpf_cnpj
    return if document.blank?

    errors.add(:document, "must be a valid CPF or CNPJ") if CpfCnpj.which(document).nil?
  end
end