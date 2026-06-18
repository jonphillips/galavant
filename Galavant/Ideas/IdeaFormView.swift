import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI
import UIKit

struct IdeaFormView: View {
  @State private var model: IdeaFormModel
  @State private var search = PlaceSearchModel()
  @Environment(\.dismiss) private var dismiss
  @FocusState private var tagFieldFocused: Bool

  init(draft: Idea.Draft) {
    _model = State(initialValue: IdeaFormModel(draft: draft))
  }

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        if !model.images.isEmpty {
          photosSection
        }

        Section {
          if model.hasLocation {
            placeCard
          } else {
            TextField("Search a place", text: $search.query)
              .textInputAutocapitalization(.words)
            ForEach(search.results) { result in
              Button {
                model.setLocation(result)
                search.query = ""
              } label: {
                VStack(alignment: .leading) {
                  Text(result.name).foregroundStyle(.primary)
                  if !result.subtitle.isEmpty {
                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        } header: {
          Text("Place")
        } footer: {
          if !model.hasLocation {
            Text("Search to auto-fill name, kind, and details — or just type a name below.")
          }
        }

        Section {
          TextField("Name", text: $model.draft.name)
          Picker("Kind", selection: $model.draft.kind) {
            Text("Unspecified").tag(IdeaKind?.none)
            ForEach(IdeaKind.allCases, id: \.self) { kind in
              Label(kind.label, systemImage: kind.systemImage).tag(IdeaKind?.some(kind))
            }
          }
        }

        Section("Tags") {
          ForEach(model.tagNames, id: \.self) { name in
            HStack {
              Icon.tag.image.foregroundStyle(.secondary)
              Text(name)
              Spacer()
              Button(role: .destructive) {
                model.removeTagName(name)
              } label: {
                Icon.remove.image.foregroundStyle(.red)
              }
              .buttonStyle(.borderless)
            }
          }
          TextField("Add a tag", text: $model.newTag)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($tagFieldFocused)
            .onSubmit { model.addTagName(model.trimmedNewTag) }
          if tagFieldFocused || !model.trimmedNewTag.isEmpty {
            ForEach(model.trimmedNewTag.isEmpty ? model.unusedSuggestions : model.matchingSuggestions, id: \.self) { name in
              Button { model.addTagName(name) } label: {
                Label(name, systemImage: Icon.tag.systemName)
              }
            }
            if !model.trimmedNewTag.isEmpty, !model.typedMatchesExisting {
              Button { model.addTagName(model.trimmedNewTag) } label: {
                Icon.addInline.label("Add “\(model.trimmedNewTag)”")
              }
            }
          }
        }

        TextField("Link", text: $model.draft.url)
          .textContentType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Toggle("Visited", isOn: $model.draft.visited)
        Section("Notes") {
          TextEditor(text: $model.draft.notes)
            .frame(minHeight: 120)
        }
      }
      .navigationTitle(model.isNew ? "New Idea" : "Edit Idea")
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
      .task { await model.task() }
    }
  }

  /// The idea's photos: a large cover preview over a tappable thumbnail strip.
  /// The enrichment's Vision-recommended cover is the default; tapping a thumbnail
  /// overrides it (M4h).
  private var photosSection: some View {
    Section {
      if let cover = model.coverImage, let image = UIImage(data: cover) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity)
          .frame(height: 180)
          .clipped()
          .listRowInsets(EdgeInsets())
      }
      if model.images.count > 1 {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(model.images) { image in
              Button { Task { await model.setHeader(image) } } label: {
                thumbnail(image)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.vertical, 6)
        }
      }
    } header: {
      Text("Photos")
    } footer: {
      if model.images.count > 1 {
        Text("Tap a photo to make it the cover.")
      }
    }
  }

  /// One gallery thumbnail; the current cover gets a tint ring + checkmark.
  private func thumbnail(_ image: ImageAsset) -> some View {
    let ui = UIImage(data: image.thumbnail)
    return ZStack(alignment: .topTrailing) {
      Group {
        if let ui {
          Image(uiImage: ui).resizable().scaledToFill()
        } else {
          Color.secondary.opacity(0.2)
        }
      }
      .frame(width: 88, height: 88)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(image.isHeader ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 3)
      }
      if image.isHeader {
        Image(systemName: Icon.checkmark.systemName)
          .font(.caption.weight(.bold))
          .foregroundStyle(.white)
          .padding(4)
          .background(.tint, in: Circle())
          .padding(4)
      }
    }
  }

  /// The confirmed place: a compact summary of what search resolved (address,
  /// phone) so the fields below read as confirm-and-tweak. Name/kind live in
  /// their own editable section; this is the location's at-a-glance identity.
  private var placeCard: some View {
    HStack(alignment: .top) {
      Icon.location.image.foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.draft.name.isEmpty ? "Pinned location" : model.draft.name)
        if let address = model.draft.address, !address.isEmpty {
          Text(address).font(.caption).foregroundStyle(.secondary)
        } else if let regionName = model.draft.regionName, !regionName.isEmpty {
          Text(regionName).font(.caption).foregroundStyle(.secondary)
        }
        if let phone = model.draft.phone, !phone.isEmpty {
          Text(phone).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("Clear", role: .destructive) { model.clearLocation() }
        .buttonStyle(.borderless)
    }
  }
}
