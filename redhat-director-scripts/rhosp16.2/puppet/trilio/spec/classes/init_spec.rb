require 'spec_helper'
describe 'trilio' do

  context 'with defaults for all parameters' do
    it { should contain_class('trilio') }
  end
end
