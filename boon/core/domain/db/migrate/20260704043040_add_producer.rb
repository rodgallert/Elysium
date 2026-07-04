class AddProducer < ActiveRecord::Migration[8.1]
  def change
    create_table :producers do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :document, null: false
      t.string :phone, null: false
      t.string :street, null: false
      t.string :number, null: false
      t.string :city, null: false
      t.string :state, null: false
      t.string :zip_code, null: false
      t.string :complement
      t.string :status, null: false, default: 'active'
      t.date :birth_date, null: false
      t.integer :failed_login_attempts, null: false, default: 0, limit: 2
      t.integer :login_blocked_count, null: false, default: 0, limit: 2
      t.datetime :last_failed_login_at, null: true
      t.datetime :login_blocked_until, null: true
      t.timestamps
      t.index :email, unique: true
      t.index :document, unique: true
    end
  end
end
