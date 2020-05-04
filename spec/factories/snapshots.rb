FactoryBot.define do
  factory :snapshot do
    audit_date { Time.zone.now }
    institution_id { FactoryBot.create(:institution).id }
    apt_bytes { rand(20_000_000..500_000_000_000) }
    cost { (apt_bytes * 0.000000000381988).round(2) }
    snapshot_type { ['Individual', 'Subscribers Included'].sample }
  end
end
