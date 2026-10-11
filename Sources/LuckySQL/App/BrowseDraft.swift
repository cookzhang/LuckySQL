import Combine

/// Editing a filter updates its controls without invalidating the sidebar,
/// result grid, or retained SQL workspace on every keystroke.
@MainActor final class BrowseDraft: ObservableObject {
    @Published var options = TableBrowseOptions()

    func hasPendingFilter(comparedTo applied: TableBrowseOptions) -> Bool {
        options.filterColumn != applied.filterColumn || options.filterOperator != applied.filterOperator || options.filterValue != applied.filterValue
    }
}
