import GalavantSchema
import SwiftUI

struct TripFormView: View {
  @State private var model: TripFormModel
  @Environment(\.dismiss) private var dismiss

  init(draft: Trip.Draft) {
    _model = State(initialValue: TripFormModel(draft: draft))
  }

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        TextField("Name", text: $model.draft.name)

        Section("Certainty") {
          Picker("Stage", selection: $model.stage) {
            ForEach(CertaintyStage.allCases, id: \.self) { stage in
              Text(stage.label).tag(stage)
            }
          }
          .pickerStyle(.segmented)

          switch model.stage {
          case .someday:
            Text("A vague idea, ranked in the backlog. No dates yet.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          case .targeted:
            Picker("Year", selection: $model.targetYear) {
              ForEach(model.selectableYears, id: \.self) { year in
                Text(String(year)).tag(year)
              }
            }
            Picker("Quarter", selection: $model.targetQuarter) {
              Text("Any").tag(Quarter?.none)
              ForEach(Quarter.allCases, id: \.self) { quarter in
                Text("\(quarter.label) (\(quarter.monthRange))").tag(Quarter?.some(quarter))
              }
            }
          case .dated:
            DatePicker(
              "Start", selection: $model.startDate, displayedComponents: .date
            )
          }
        }

        Section("Duration") {
          Stepper(
            "^[\(model.lengthInDays) day](inflect: true)",
            value: $model.lengthInDays,
            in: 1...60
          )
        }

        Section {
          if model.sortedRegions.isEmpty {
            Text("No regions yet — define them on the Ideas map.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            ForEach(model.sortedRegions) { region in
              Button {
                model.toggleRegion(region.id)
              } label: {
                HStack {
                  Text(region.name).foregroundStyle(.primary)
                  Spacer()
                  if model.selectedRegionIDs.contains(region.id) {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                  }
                }
              }
            }
          }
        } header: {
          Text("Regions")
        } footer: {
          Text("The Add list pre-selects these when you plan the trip.")
        }

        Section("Notes") {
          TextEditor(text: $model.draft.notes)
            .frame(minHeight: 120)
        }
      }
      .task { await model.task() }
      .navigationTitle(model.isNew ? "New Trip" : "Edit Trip")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            model.saveButtonTapped()
            dismiss()
          }
          .disabled(!model.canSave)
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}
