/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit

extension NSScreen {
    /// The primary display — `NSScreen.screens[0]`, the one holding the menu bar.
    ///
    /// Prefer this over `NSScreen.main` for anything that should be *stable*.
    /// Despite the name, `NSScreen.main` is not the primary display: it's
    /// whichever screen currently holds the key window, falling back to the one
    /// under the pointer. On a multi-display setup its value therefore depends
    /// on where the user happened to be looking when the code ran, so using it
    /// as a stored default meant the notch could settle on the external monitor
    /// purely because the pointer was there at launch.
    ///
    /// `NSScreen.main` is still the right call where "the display the user is
    /// working on" is genuinely what's wanted — e.g. the automatic
    /// display-switching path, or positioning a transient panel.
    static var primary: NSScreen? { NSScreen.screens.first }
}
