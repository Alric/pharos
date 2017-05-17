require 'spec_helper'

RSpec.describe DpnWorkItemsController, type: :controller do

  before :all do
    DpnWorkItem.delete_all
  end

  after do
    DpnWorkItem.delete_all
  end

  let!(:admin_user) { FactoryGirl.create(:user, :admin) }
  let!(:institutional_admin) { FactoryGirl.create(:user, :institutional_admin) }
  let!(:item_one) { FactoryGirl.create(:dpn_work_item, task: 'sync', remote_node: 'aptrust', identifier: '1234') }
  let!(:item_two) { FactoryGirl.create(:dpn_work_item, task: 'ingest', remote_node: 'chronopolis', identifier: '5678', queued_at: nil) }

  describe '#GET index' do
    describe 'for admin users' do
      before do
        sign_in admin_user
      end

      it 'returns successfully when no parameters are given' do
        get :index, format: :json
        expect(response).to be_success
        expect(assigns(:paged_results).size).to eq 2
      end

      it 'filters by identifier' do
        get :index, params: { identifier: '1234' }, format: :json
        expect(response).to be_success
        expect(assigns(:paged_results).size).to eq 1
        expect(assigns(:paged_results).map &:id).to match_array [item_one.id]
      end

      it 'filters by remote node' do
        get :index, params: { remote_node: 'chronopolis' }, format: :json
        expect(response).to be_success
        expect(assigns(:paged_results).size).to eq 1
        expect(assigns(:paged_results).map &:id).to match_array [item_two.id]
      end

      it 'filters by task' do
        get :index, params: { task: 'sync' }, format: :json
        expect(response).to be_success
        expect(assigns(:paged_results).size).to eq 1
        expect(assigns(:paged_results).map &:id).to match_array [item_one.id]
      end

      it 'filters by queued items' do
        get :index, params: { queued: 'is_queued' }
        expect(response).to be_success
        expect(assigns(:paged_results).size).to eq 1
        expect(assigns(:paged_results).map &:id).to match_array [item_one.id]
      end

      it 'filters by not queued items' do
        get :index, params: { queued: 'is_not_queued' }
        expect(response).to be_success
        expect(assigns(:paged_results).size).to eq 1
        expect(assigns(:paged_results).map &:id).to match_array [item_two.id]
      end
    end

    describe 'for institutional admin users' do
      before do
        sign_in institutional_admin
      end

      it 'denies access' do
        get :index, format: :json
        expect(response.status).to eq(403)
      end
    end

  end

  describe 'POST #create' do
    before do
      sign_in admin_user
    end

    it 'successfully creates the dpn item' do
      post :create, params: { dpn_work_item: { remote_node: 'aptrust', task: 'sync', identifier: '12345678', state: 'Active' } }, format: :json
      expect(response).to be_success
      assigns(:dpn_item).remote_node.should eq('aptrust')
      assigns(:dpn_item).task.should eq('sync')
      assigns(:dpn_item).identifier.should eq('12345678')
      assigns(:dpn_item).state.should eq('Active')
    end

    describe 'for institutional admin users' do
      before do
        sign_in institutional_admin
      end

      it 'denies access' do
        post :create, params: { dpn_work_item: { remote_node: 'aptrust', task: 'sync', identifier: '12345678' } }, format: :json
        expect(response.status).to eq(403)
      end
    end
  end

  describe 'PUT #update' do
    describe 'for admin user' do
      before do
        sign_in admin_user
      end

      it 'responds successfully with both the action and the state updated' do
        put :update, params: { id: item_one.id, dpn_work_item: { note: 'Testing the update method', state: 'NEW'} }, format: :json
        expect(response).to be_success
        assigns(:dpn_item).id.should eq(item_one.id)
        assigns(:dpn_item).note.should eq('Testing the update method')
        assigns(:dpn_item).state.should eq('NEW')
      end

      it 'responds with a 404 error if the dpn item does not exist' do
        put :update, params: { id: '2345336', dpn_work_item: { note: 'Testing the update method'} }, format: :json
        expect(response.status).to eq(404)
      end
    end

    describe 'for institutional admin users' do
      before do
        sign_in institutional_admin
      end

      it 'denies access' do
        put :update, params: { id: item_one.id, dpn_work_item: { note: 'Testing the update method'} }, format: :json
        expect(response.status).to eq(403)
      end
    end
  end

  describe 'GET #show' do
    describe 'for admin user' do
      before do
        sign_in admin_user
      end

      it 'responds successfully with both the work item and the state item set' do
        get :show, params: { id: item_two.id }, format: :json
        expect(response).to be_success
        assigns(:dpn_item).id.should eq(item_two.id)
        assigns(:dpn_item).remote_node.should eq('chronopolis')
      end

      it 'responds with a 404 error if the dpn item does not exist' do
        get :show, params: { id: '2345336' }, format: :json
        expect(response.status).to eq(404)
      end
    end

    describe 'for institutional admin users' do
      before do
        sign_in institutional_admin
      end

      it 'denies access' do
        get :show, params: { id: item_one.id }, format: :json
        expect(response.status).to eq(403)
      end
    end
  end

  describe 'GET #requeue' do
    describe 'for admin user' do
      before do
        sign_in admin_user
      end
      it 'responds successfully with an HTTP 200 status code' do
        get :requeue, params: { id: item_one.id, delete_state_item: 'false', task: 'store' }
        expect(response).to be_success
      end

      it 'renders the requeue template' do
        get :requeue, params: { id: item_one.id, delete_state_item: 'false', task: 'store' }
        expect(response).to render_template('requeue')
      end

      it 'assigns the requested item as @dpn_item' do
        get :requeue, params: { id: item_one.id, delete_state_item: 'false', task: 'store' }
        assigns(:dpn_item).id.should eq(item_one.id)
      end

    end

    describe 'for institutional admin' do
      before do
        sign_in institutional_admin
      end

      it 'does not allow the user to requeue the item' do
        get :requeue, params: { id: item_one.id, delete_state_item: 'false', task: 'store' }, format: :json
        expect(response.status).to eq 403
      end

    end
  end

end
