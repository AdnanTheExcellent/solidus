require 'spec_helper'

describe Spree::ReturnAuthorization, type: :model do
  let(:order) { create(:shipped_order) }
  let(:stock_location) { create(:stock_location) }
  let(:rma_reason) { create(:return_reason) }
  let(:inventory_unit_1) { order.inventory_units.first }

  let(:variant) { order.variants.first }
  let(:return_authorization) do
    Spree::ReturnAuthorization.new(order: order,
      stock_location_id: stock_location.id,
      return_reason_id: rma_reason.id)
  end

  context "save" do
    let(:order) { Spree::Order.create }

    it "should be invalid when order has no inventory units" do
      order.inventory_units.each(&:delete)
      return_authorization.save
      expect(return_authorization.errors[:order]).to eq(["has no shipped units"])
    end

    context "an inventory unit is already being exchanged" do
      let(:order)                           { create(:shipped_order, line_items_count: 2) }
      let!(:previous_exchange_return_item)  { create(:exchange_return_item, inventory_unit: order.inventory_units.last) }
      let(:return_item)                     { create(:return_item, inventory_unit: order.inventory_units.last) }
      let(:return_authorization)            { build(:return_authorization, order: order, return_items: [return_item]) }

      it "should be invalid" do
        return_authorization.save
        expect(return_authorization.errors['base']).to include('Return items cannot be created for inventory units that are already awaiting exchange.')
      end
    end

    context "an inventory unit is not being exchanged" do
      let(:order)                           { create(:shipped_order, line_items_count: 2) }
      let(:return_item)                     { create(:return_item, inventory_unit: order.inventory_units.last) }
      let(:return_authorization)            { build(:return_authorization, order: order, return_items: [return_item]) }

      it "is valid" do
        return_authorization.save
        expect(return_authorization.errors['base'].size).to eq 0
      end
    end

    context "expedited exchanges are configured" do
      let(:order)                { create(:shipped_order, line_items_count: 2) }
      let(:exchange_return_item) { build(:exchange_return_item, inventory_unit: order.inventory_units.first) }
      let(:return_item)          { build(:return_item, inventory_unit: order.inventory_units.last) }
      subject                    { create(:return_authorization, order: order, return_items: [exchange_return_item, return_item]) }

      before do
        Spree::Config[:expedited_exchanges] = true
        @pre_exchange_hooks = subject.class.pre_expedited_exchange_hooks
      end

      after do
        subject.class.pre_expedited_exchange_hooks = @pre_exchange_hooks
      end

      context "no items to exchange" do
        subject { create(:return_authorization, order: order) }

        it "does not create a reimbursement" do
          expect{ subject.save }.to_not change { Spree::Reimbursement.count }
        end
      end

      context "items to exchange" do
        it "calls pre_expedited_exchange hooks with the return items to exchange" do
          hook = double(:as_null_object)
          expect(hook).to receive(:call).with [exchange_return_item]
          subject.class.pre_expedited_exchange_hooks = [hook]
          subject.save
        end

        it "attempts to accept all return items requiring exchange" do
          expect(exchange_return_item).to receive :attempt_accept
          expect(return_item).not_to receive :attempt_accept
          subject.save
        end

        it "performs an exchange reimbursement for the exchange return items" do
          subject.save
          reimbursement = Spree::Reimbursement.last
          expect(reimbursement.order).to eq subject.order
          expect(reimbursement.return_items).to eq [exchange_return_item]
          expect(exchange_return_item.reload.exchange_shipment).to be_present
        end

        context "the reimbursement fails" do
          before do
            allow_any_instance_of(Spree::Reimbursement).to receive(:save) { false }
            allow_any_instance_of(Spree::Reimbursement).to receive(:errors) { double(full_messages: "foo") }
          end

          it "puts errors on the return authorization" do
            subject.save
            expect(subject.errors[:base]).to include "foo"
          end
        end
      end
    end
  end

  describe ".before_create" do
    describe "#generate_number" do
      context "number is assigned" do
        let(:return_authorization) { Spree::ReturnAuthorization.new(number: '123') }

        it "should return the assigned number" do
          return_authorization.save
          expect(return_authorization.number).to eq('123')
        end
      end

      context "number is not assigned" do
        let(:return_authorization) { Spree::ReturnAuthorization.new(number: nil) }

        before { allow(return_authorization).to receive_messages valid?: true }

        it "should assign number with random RA number" do
          return_authorization.save
          expect(return_authorization.number).to match(/RA\d{9}/)
        end
      end
    end
  end

  context "#currency" do
    before { allow(order).to receive(:currency) { "ABC" } }
    it "returns the order currency" do
      expect(return_authorization.currency).to eq("ABC")
    end
  end

  describe "#pre_tax_total" do
    let(:pre_tax_amount_1) { 15.0 }
    let!(:return_item_1) { create(:return_item, return_authorization: return_authorization, pre_tax_amount: pre_tax_amount_1) }

    let(:pre_tax_amount_2) { 50.0 }
    let!(:return_item_2) { create(:return_item, return_authorization: return_authorization, pre_tax_amount: pre_tax_amount_2) }

    let(:pre_tax_amount_3) { 5.0 }
    let!(:return_item_3) { create(:return_item, return_authorization: return_authorization, pre_tax_amount: pre_tax_amount_3) }

    subject { return_authorization.pre_tax_total }

    it "sums it's associated return_item's pre-tax amounts" do
      expect(subject).to eq(pre_tax_amount_1 + pre_tax_amount_2 + pre_tax_amount_3)
    end
  end

  describe "#display_pre_tax_total" do
    it "returns a Spree::Money" do
      allow(return_authorization).to receive_messages(pre_tax_total: 21.22)
      expect(return_authorization.display_pre_tax_total).to eq(Spree::Money.new(21.22))
    end
  end

  context "can_receive?" do
    before do
      pending "TODO: get this method into our fork"
    end

    it "should allow_receive when inventory units assigned" do
      allow(return_authorization).to receive_messages(inventory_units: [1, 2, 3])
      expect(return_authorization.can_receive?).to be true
    end

    it "should not allow_receive with no inventory units" do
      allow(return_authorization).to receive_messages(inventory_units: [])
      expect(return_authorization.can_receive?).to be false
    end
  end

  describe "#refundable_amount" do
    let(:weighted_line_item_pre_tax_amount) { 5.0 }
    let(:line_item_count)                   { return_authorization.order.line_items.count }

    subject { return_authorization.refundable_amount }

    before do
      return_authorization.order.line_items.update_all(pre_tax_amount: weighted_line_item_pre_tax_amount)
      return_authorization.order.update_attribute(:promo_total, promo_total)
    end

    context "no promotions" do
      let(:promo_total) { 0.0 }
      it "returns the pre-tax line item total" do
        expect(subject).to eq(weighted_line_item_pre_tax_amount * line_item_count)
      end
    end

    context "promotions" do
      let(:promo_total) { -10.0 }
      it "returns the pre-tax line item total minus the order level promotion value" do
        expect(subject).to eq((weighted_line_item_pre_tax_amount * line_item_count) + promo_total)
      end
    end
  end

  describe "#customer_returned_items?" do
    before do
      allow_any_instance_of(Spree::Order).to receive_messages(return!: true)
    end

    subject { return_authorization.customer_returned_items? }

    context "has associated customer returns" do
      let(:customer_return) { create(:customer_return) }
      let(:return_authorization) { customer_return.return_authorizations.first }

      it "returns true" do
        expect(subject).to eq true
      end
    end

    context "does not have associated customer returns" do
      let(:return_authorization) { create(:return_authorization) }

      it "returns false" do
        expect(subject).to eq false
      end
    end
  end

  describe 'cancel_return_items' do
    let(:return_authorization) { create(:return_authorization, return_items: return_items) }
    let(:return_items) { [return_item] }
    let(:return_item) { create(:return_item) }

    subject {
      return_authorization.cancel!
    }

    it 'cancels the associated return items' do
      subject
      expect(return_item.reception_status).to eq 'cancelled'
    end

    context 'some return items cannot be cancelled' do
      let(:return_items) { [return_item, return_item_2] }
      let(:return_item_2) { create(:return_item, reception_status: 'received') }

      it 'cancels those that can be cancelled' do
        subject
        expect(return_item.reception_status).to eq 'cancelled'
        expect(return_item_2.reception_status).to eq 'received'
      end
    end
  end

  describe '#can_cancel?' do
    subject { create(:return_authorization, return_items: return_items).can_cancel? }
    let(:return_items) { [return_item_1, return_item_2] }
    let(:return_item_1) { create(:return_item) }
    let(:return_item_2) { create(:return_item) }

    context 'all items can be cancelled' do
      it 'returns true' do
        expect(subject).to eq true
      end
    end

    context 'at least one return item can be cancelled' do
      let(:return_item_2) { create(:return_item, reception_status: 'received') }

      it { is_expected.to eq true }
    end

    context 'no items can be cancelled' do
      let(:return_item_1) { create(:return_item, reception_status: 'received') }
      let(:return_item_2) { create(:return_item, reception_status: 'received') }

      it { is_expected.to eq false }
    end

    context 'when return_authorization has no return_items' do
      let(:return_items) { [] }

      it { is_expected.to eq true }
    end
  end
end
