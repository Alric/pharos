require 'spec_helper'

describe StatisticsSampler do
  before do
    Institution.delete_all
    3.times { FactoryBot.create(:member_institution) }
  end
  it 'should record statistics' do
    expect { StatisticsSampler.record_current_statistics }.to change { UsageSample.count }.by(3)
  end
end
