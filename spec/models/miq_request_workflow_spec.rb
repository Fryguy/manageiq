require "spec_helper"

describe MiqRequestWorkflow do
  context "#validate" do
    let(:dialog)   { workflow.instance_variable_get(:@dialogs) }
    let(:workflow) { FactoryGirl.build(:miq_provision_workflow) }

    context "validation_method" do
      it "skips validation if no validation_method is defined" do
        expect(workflow.get_all_dialogs[:customize][:fields][:root_password][:validation_method]).to eq(nil)
        expect(workflow.validate({})).to be_true
      end

      it "calls the validation_method if defined" do
        dialog.store_path(:dialogs, :customize, :fields, :root_password, :validation_method, :some_validation_method)

        expect(workflow).to receive(:respond_to?).with(:some_validation_method).and_return(true)
        expect(workflow).to receive(:some_validation_method).once
        expect(workflow.validate({})).to be_true
      end

      it "returns false when validation fails" do
        dialog.store_path(:dialogs, :customize, :fields, :root_password, :validation_method, :some_validation_method)

        expect(workflow).to receive(:respond_to?).with(:some_validation_method).and_return(true)
        expect(workflow).to receive(:some_validation_method).and_return("Some Error")
        expect(workflow.validate({})).to be_false
      end
    end

    context 'required_method is only run on visible fields' do
      it "field hidden" do
        dialog.store_path(:dialogs, :customize, :fields, :root_password, :required_method, :some_required_method)
        dialog.store_path(:dialogs, :customize, :fields, :root_password, :required, true)
        dialog.store_path(:dialogs, :customize, :fields, :root_password, :display, :hide)

        expect(workflow).to_not receive(:some_required_method)
        expect(workflow.validate({})).to be_true
      end

      it "field visible" do
        dialog.store_path(:dialogs, :customize, :fields, :root_password, :required_method, :some_required_method)
        dialog.store_path(:dialogs, :customize, :fields, :root_password, :required, true)

        expect(workflow).to receive(:some_required_method).and_return("Some Error")
        expect(workflow.validate({})).to be_false
      end
    end
  end

  describe "#init_from_dialog" do
    let(:dialogs) { workflow.instance_variable_get(:@dialogs) }
    let(:workflow) { FactoryGirl.build(:miq_provision_workflow) }
    let(:init_values) { {} }

    context "when the initial values already have a value for the field name" do
      let(:init_values) { {:root_password => "root"} }

      it "does not modify the initial values" do
        workflow.init_from_dialog(init_values, 123)
        expect(init_values).to eq(:root_password => "root")
      end
    end

    context "when the dialog fields ignore display" do
      before do
        dialogs[:dialogs].keys.each do |dialog_name|
          workflow.get_all_fields(dialog_name).each_pair do |_, field_values|
            field_values[:display] = :ignore
          end
        end
      end

      it "does not modify the initial values" do
        workflow.init_from_dialog(init_values, 123)

        expect(init_values).to eq({})
      end
    end

    context "when the dialog field values default is not nil" do
      before do
        dialogs[:dialogs].keys.each do |dialog_name|
          workflow.get_all_fields(dialog_name).each_pair do |_, field_values|
            field_values[:default] = "not nil"
          end
        end
      end

      it "modifies the initial values with the default value" do
        workflow.init_from_dialog(init_values, 123)

        expect(init_values).to eq(:root_password => "not nil")
      end
    end

    context "when the dialog field values default is nil" do
      before do
        dialogs[:dialogs].keys.each do |dialog_name|
          workflow.get_all_fields(dialog_name).each_pair do |_, field_values|
            field_values[:default] = nil
          end
        end
      end

      context "when the field values are a hash" do
        before do
          dialogs[:dialogs].keys.each do |dialog_name|
            workflow.get_all_fields(dialog_name).each_pair do |_, field_values|
              field_values[:values] = {:something => "test"}
            end
          end
        end

        it "uses the first field value" do
          workflow.init_from_dialog(init_values, 123)

          expect(init_values).to eq(:root_password => [:something, "test"])
        end
      end

      context "when the field values are not a hash" do
        before do
          dialogs[:dialogs].keys.each do |dialog_name|
            workflow.get_all_fields(dialog_name).each_pair do |_, field_values|
              field_values[:values] = [%w(test 100), %w(test2 0)]
            end
          end
        end

        it "uses values as [value, description] for timezones aray" do
          workflow.init_from_dialog(init_values, 123)

          expect(init_values).to eq(:root_password => [nil, "test2"])
        end
      end
    end
  end

  describe "#provisioning_tab_list" do
    let(:dialogs) { workflow.instance_variable_get(:@dialogs) }
    let(:workflow) { FactoryGirl.build(:miq_provision_workflow) }

    before do
      dialogs[:dialog_order] = [:test, :test2, :test3]
      dialogs[:dialogs][:test] = {:description => "test description", :display => :hide}
      dialogs[:dialogs][:test2] = {:description => "test description 2", :display => :ignore}
      dialogs[:dialogs][:test3] = {:description => "test description 3", :display => :edit}
    end

    it "returns a list of tabs without the hidden or ignored ones" do
      expect(workflow.provisioning_tab_list).to eq([{:name => "test3", :description => "test description 3"}])
    end
  end
end
