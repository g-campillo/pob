enum RailVisibility {
    case hidden
    case hover
    case pinned
}

struct RailState: Equatable {
    private(set) var visibility: RailVisibility = .hidden
    private(set) var isEditingAddress = false

    mutating func pointerDwelledAtEdge() {
        if visibility == .hidden {
            visibility = .hover
        }
    }

    mutating func pointerLeftRail() {
        if visibility == .hover, !isEditingAddress {
            visibility = .hidden
        }
    }

    mutating func toggleShortcut() {
        visibility = visibility == .pinned ? .hidden : .pinned
        if visibility == .hidden {
            isEditingAddress = false
        }
    }

    mutating func beginEditingAddress() {
        isEditingAddress = true
        if visibility == .hidden {
            visibility = .hover
        }
    }

    mutating func endEditingAddress(pointerInsideRail: Bool) {
        isEditingAddress = false
        if visibility == .hover, !pointerInsideRail {
            visibility = .hidden
        }
    }
}
