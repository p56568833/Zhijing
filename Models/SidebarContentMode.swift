enum SidebarContentMode: String, CaseIterable, Identifiable {
    case library = "文库"
    case outline = "大纲"

    var id: Self { self }
}
