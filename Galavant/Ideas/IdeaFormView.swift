import GalavantPlaces
import GalavantSchema
import WebExtractorKit
import MapKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IdeaFormView: View {
  @State private var model: IdeaFormModel
  @State private var search: PlaceSearchModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var tagFieldFocused: Bool
  @State private var photosItem: PhotosPickerItem?
  private let saveTitle: String
  private let onSave: (@MainActor (Idea.ID) async -> Void)?

  init(
    draft: Idea.Draft,
    searchRegions: [MapRegion] = [],
    saveTitle: String = "Save",
    onSave: (@MainActor (Idea.ID) async -> Void)? = nil
  ) {
    _model = State(initialValue: IdeaFormModel(draft: draft))
    _search = State(initialValue: PlaceSearchModel(regions: searchRegions))
    self.saveTitle = saveTitle
    self.onSave = onSave
  }

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        if !model.isNew || !model.images.isEmpty {
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
          StackedTextField(title: "Name", text: $model.draft.name)
          StackedFormField(title: "Kind") {
            Picker("Kind", selection: $model.draft.kind) {
              Text("Unspecified").tag(IdeaKind?.none)
              ForEach(IdeaKind.allCases, id: \.self) { kind in
                Label(kind.label, systemImage: kind.systemImage).tag(IdeaKind?.some(kind))
              }
            }
            .labelsHidden()
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
          // The "manage many" surface (BACKLOG "Multi-select tag assignment on
          // Ideas"): a checkmark list of every tag, for toggling several at once
          // instead of the one-at-a-time flow above.
          NavigationLink {
            TagPickerView(model: model)
          } label: {
            Icon.tagPicker.label("Select from all tags…")
          }
        }

        StackedFormField(title: "Link") {
          TextField("Link", text: $model.draft.url, prompt: Text(verbatim: "https://…"))
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        Toggle("Visited", isOn: $model.draft.visited)
        if !model.isNew {
          hoursSection
        }
        StructuredHoursEditor(model: model)
        if model.canFindGuideRating {
          guideRatingSection
        }
        Section {
          StackedTextEditor(title: "Description", text: $model.draft.description, minHeight: 80)
        }
        Section {
          StackedTextEditor(title: "Notes", text: $model.draft.notes, minHeight: 120)
        }
      }
      .sheet(
        isPresented: Binding(
          get: { model.hoursBrowserURL != nil },
          set: { if !$0 { model.hoursBrowserURL = nil } }
        )
      ) {
        if let url = model.hoursBrowserURL {
          // The human-in-the-loop rung of the field-supplement ladder (ADR-0016 §2):
          // Jon drives the in-app browser to a page with hours, then "Use This Page"
          // runs the parser over the rendered DOM. The browser is the app-agnostic
          // GalavantWeb component (ADR-0022); the hours plugin lives here.
          WebExtractorBrowser(startURL: url, title: "Find Hours", confirmLabel: "Use This Page") {
            html, sourceURL in
            await model.applyBrowsedHours(html: html, sourceURL: sourceURL)
              ? .extracted
              : .notFound(message: "No hours found on this page. Navigate to the hours and try again.")
          }
        }
      }
      .sheet(
        isPresented: Binding(
          get: { model.guideBrowserURL != nil },
          set: { if !$0 { model.guideBrowserURL = nil } }
        )
      ) {
        if let url = model.guideBrowserURL {
          // The HITL guide-link fallback (ADR-0023, the ADR-0021 next rung): Jon drives
          // the in-app browser to a guide-detail page the automated plain fetch couldn't
          // render, then "Use This Page" reads the rating off the DOM. Same GalavantWeb
          // component (ADR-0022); the guide-rating plugin lives here.
          WebExtractorBrowser(startURL: url, title: "Find Rating", confirmLabel: "Use This Page") {
            html, sourceURL in
            await model.applyBrowsedGuide(html: html, sourceURL: sourceURL)
              ? .extracted
              : .notFound(message: "No rating found on this page. Navigate to the guide listing and try again.")
          }
        }
      }
      .navigationTitle(model.isNew ? "New Idea" : "Edit Idea")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(saveTitle) {
            if let ideaID = model.saveButtonTapped() {
              Task { await onSave?(ideaID) }
            }
            dismiss()
          }
          .disabled(!model.canSave)
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .onChange(of: photosItem) { _, item in
        guard let item else { return }
        Task {
          defer { photosItem = nil }
          if let data = try? await item.loadTransferable(type: Data.self) {
            await model.addImage(data)
          } else {
            model.imagesStatus = "Couldn't load that photo. Try another."
          }
        }
      }
      .task { await model.task() }
    }
  }

  /// Opening hours (a *fact* on the idea, ADR-0016 §2): the current value with its
  /// provenance, and the supplement affordance that fills it from the cheapest
  /// source — the place's own site, falling through to an in-app browser.
  @ViewBuilder private var hoursSection: some View {
    @Bindable var model = model
    Section("Hours") {
      if let hours = model.draft.openingHours, !hours.isEmpty {
        Text(hours)
        if let provenance = model.draft.hoursProvenance {
          Label(hoursProvenanceText(provenance), systemImage: "checkmark.seal")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("No hours yet").foregroundStyle(.secondary)
      }
      if model.canSupplementHours {
        Button {
          Task { await model.supplementHours() }
        } label: {
          if model.supplementingHours {
            Label { Text("Finding hours…") } icon: { ProgressView() }
          } else {
            Label(
              model.draft.openingHours == nil ? "Find hours" : "Refresh hours",
              systemImage: "clock"
            )
          }
        }
        .disabled(model.supplementingHours)
      }
      if let status = model.hoursStatus {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The guide-rating fallback (ADR-0023, the ADR-0021 HITL rung): when an idea's page
  /// links to a guide-detail page whose plain fetch can't be read, follow it on demand —
  /// recording the rating directly when it renders, or opening the in-app browser when it
  /// doesn't. A *judgment* (sibling `IdeaEvaluation`), so it lives apart from the hours
  /// *fact* section above.
  @ViewBuilder private var guideRatingSection: some View {
    Section("Guide rating") {
      Button {
        Task { await model.supplementGuideRating() }
      } label: {
        if model.findingGuideRating {
          Label { Text("Checking guide…") } icon: { ProgressView() }
        } else {
          Label("Check guide page", systemImage: "rosette")
        }
      }
      .disabled(model.findingGuideRating)
      if let status = model.guideRatingStatus {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// "Verified · Jun 22, 2026" — the provenance label plus the verified date.
  private func hoursProvenanceText(_ provenance: FactProvenance) -> String {
    guard let date = model.draft.hoursVerifiedAt else { return provenance.label }
    return "\(provenance.label) · \(date.formatted(date: .abbreviated, time: .omitted))"
  }

  /// The idea's photos: a large cover preview over a tappable thumbnail strip.
  /// The enrichment's Vision-recommended cover is the default; tapping a thumbnail
  /// overrides it (M4h).
  private var photosSection: some View {
    Section {
      if let cover = model.coverImage, let image = UIImage(data: cover) {
        // Fit (not fill) so the whole image shows — many og:images are wide
        // wordmarks/logos that a fill crop zooms into unrecognizably.
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity)
          .frame(maxHeight: 220)
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
      if model.canRefetchImages {
        Button {
          Task { await model.refetchImages() }
        } label: {
          if model.refetchingImages {
            Label { Text("Refreshing images…") } icon: { ProgressView() }
          } else {
            Label("Refresh images from website", systemImage: "arrow.clockwise")
          }
        }
        .disabled(model.refetchingImages || model.addingImage)
      }
    } header: {
      Text("Photos")
    } footer: {
      if model.images.count > 1 {
        Text("Tap a photo to make it the cover.")
      }
      if !model.isNew {
        HStack {
          PhotosPicker(selection: $photosItem, matching: .images) {
            Label("Add from Photos", systemImage: "photo.on.rectangle")
          }

          PasteButton(supportedContentTypes: [.image]) { providers in
            Task {
              guard let provider = providers.first,
                let data = await loadImageData(from: provider)
              else {
                model.imagesStatus = "Couldn't load that image. Try again."
                return
              }
              await model.addImage(data)
            }
          }
        }
        if model.addingImage {
          Label { Text("Adding image…") } icon: { ProgressView() }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if let status = model.imagesStatus {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// One gallery thumbnail; the current cover gets a tint ring + checkmark.
  private func thumbnail(_ image: ImageAsset) -> some View {
    let ui = UIImage(data: image.thumbnail)
    return ZStack(alignment: .topTrailing) {
      Group {
        if let ui {
          // Fit, not fill — wordmark/logo candidates shouldn't be cropped to a zoom.
          Image(uiImage: ui).resizable().scaledToFit()
        } else {
          Color.secondary.opacity(0.2)
        }
      }
      .frame(width: 88, height: 88)
      .background(Color(.secondarySystemFill))
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

  /// Bridge the paste provider's callback API to async/await for the model's
  /// shared image-ingestion path.
  private func loadImageData(from provider: NSItemProvider) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
        continuation.resume(returning: data)
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
