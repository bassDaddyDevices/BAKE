import XCTest

final class CanvasUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches with one new, empty document window.
    @MainActor
    private func launchWithNewDocument() -> XCUIApplication {
        let app = XCUIApplication()
        // Don't reopen windows from earlier runs — their cards would match the queries below.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        // Document apps may open with an Open panel; dismiss it, then make a new document.
        if app.dialogs.firstMatch.waitForExistence(timeout: 2) || app.sheets.firstMatch.exists {
            app.typeKey(.escape, modifierFlags: [])
        }
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    /// Add Node is grouped into submenus (In & Out, Effects, …): open the group, then pick the node.
    @MainActor
    private func addNode(_ title: String, from group: String, in app: XCUIApplication) {
        app.menuButtons["addNode"].firstMatch.click()
        app.menuItems[group].firstMatch.hover()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 2), "\(title) is not in \(group)")
        item.click()
    }

    /// Pans the 100-node stress graph: a crash check for big graphs. Not a performance benchmark —
    /// XCTest walks every card's accessibility tree on each scroll and dominates the main thread;
    /// measure with the app's `-bakeBenchmark` launch argument instead (see WorkspaceView).
    @MainActor
    func testPanningTheStressGraph() {
        let app = launchWithNewDocument()
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Replace with Stress Graph (100 Nodes)"].click()
        XCTAssertTrue(app.descendants(matching: .any)["node.filters"].firstMatch.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(5)
        var direction: CGFloat = 1
        while Date() < deadline {
            for _ in 0..<10 { window.scroll(byDeltaX: 40 * direction, deltaY: 25 * direction) }
            direction = -direction
        }
    }

    @MainActor
    func testAddingANodeCanBeUndoneAndRedone() {
        let app = launchWithNewDocument()
        addNode("Filters", from: "Effects", in: app)
        let card = app.descendants(matching: .any)["node.filters"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(card.waitForNonExistence(timeout: 2))

        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(card.waitForExistence(timeout: 2))
    }

    /// Product-owner report: clicking a Bake card's folder did nothing (a picker nested inside the
    /// toolbar's never opened). The card's folder line must open the open panel.
    @MainActor
    func testABakeCardsFolderOpensThePicker() {
        let app = launchWithNewDocument()
        addNode("Bake", from: "In & Out", in: app)
        let folder = app.descendants(matching: .any)["bakeFolder"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 2))

        folder.click()

        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3) || app.sheets.firstMatch.waitForExistence(timeout: 1), "no open panel appeared")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testTickingAParameterSpawnsAPinAndUndoRemovesIt() {
        let app = launchWithNewDocument()
        addNode("Filters", from: "Effects", in: app)
        let card = app.descendants(matching: .any)["node.filters"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.buttons["flip"].click()
        // The card body flips over 0.35 s; a click during the turn lands on the moving face.
        Thread.sleep(forTimeInterval: 1)
        card.checkBoxes["Cutoff"].click()
        XCTAssertEqual(card.checkBoxes["Cutoff"].value as? Int, 1, "checkbox click did not toggle")

        let pin = app.descendants(matching: .any)["pin.mod.cutoff"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 2))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(pin.waitForNonExistence(timeout: 2))
    }

    /// Product-owner request: Add Node is grouped (In & Out, Effects, Spectral, Routing, Modulation).
    @MainActor
    func testAddNodeIsGroupedIntoSubmenus() {
        let app = launchWithNewDocument()
        app.menuButtons["addNode"].firstMatch.click()
        for group in ["In & Out", "Effects", "Time", "Spectral", "Routing", "Modulation"] {
            XCTAssertTrue(app.menuItems[group].firstMatch.waitForExistence(timeout: 2), "no \(group) group")
        }
        XCTAssertFalse(app.menuItems["Clock"].firstMatch.isHittable, "nodes should sit inside groups, not at the top level")
        app.typeKey(.escape, modifierFlags: [])

        addNode("Clock", from: "Modulation", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["node.clock"].firstMatch.waitForExistence(timeout: 2))
    }

    /// Controls a setting makes irrelevant are hidden: FIR Length only shows for Linear phase.
    @MainActor
    func testFIRLengthAppearsOnlyForLinearPhase() {
        let app = launchWithNewDocument()
        addNode("Filters", from: "Effects", in: app)
        let card = app.descendants(matching: .any)["node.filters"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        let firLength = card.staticTexts["FIR Length"]

        card.buttons["flip"].click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(firLength.exists, "FIR Length shown for minimum phase")
        card.buttons["flip"].click()
        Thread.sleep(forTimeInterval: 1)

        // Page 1 menus: Type, then Phase.
        card.popUpButtons.element(boundBy: 1).click()
        app.menuItems["Linear (FIR)"].firstMatch.click()
        card.buttons["flip"].click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(firLength.waitForExistence(timeout: 2), "FIR Length missing for linear phase")
    }

    /// Step FX's cells edit the pattern: a click moves a cell to the next effect, and undo puts it back.
    @MainActor
    func testClickingAStepCellCyclesItsEffect() {
        let app = launchWithNewDocument()
        addNode("Step FX", from: "Time", in: app)
        let card = app.descendants(matching: .any)["node.stepFX"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        let first = card.buttons["step.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        XCTAssertEqual(first.value as? String, "Pass")
        first.click()
        XCTAssertTrue(waitForValue("Stutter", of: first), "the click didn't change the step")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForValue("Pass", of: first), "undo didn't restore the step")
    }

    /// Owner request: exact values can be typed. Click a value, type, press Return; whole-number
    /// settings round what is typed.
    @MainActor
    func testTypingAnExactValue() {
        let app = launchWithNewDocument()
        addNode("Clock", from: "Modulation", in: app)
        let clock = app.descendants(matching: .any)["node.clock"].firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 2))
        let bpm = clock.textFields["value.bpm"]
        XCTAssertTrue(bpm.waitForExistence(timeout: 2))
        bpm.click()
        bpm.typeKey("a", modifierFlags: .command)
        bpm.typeText("140.5\r")
        XCTAssertTrue(waitForValue("140.5", of: bpm), "BPM didn't take the typed value")

        addNode("Step FX", from: "Time", in: app)
        let stepFX = app.descendants(matching: .any)["node.stepFX"].firstMatch
        XCTAssertTrue(stepFX.waitForExistence(timeout: 2))
        let steps = stepFX.textFields["value.steps"]
        XCTAssertTrue(steps.waitForExistence(timeout: 2))
        steps.click()
        steps.typeKey("a", modifierFlags: .command)
        steps.typeText("7.6\r")
        XCTAssertTrue(waitForValue("8", of: steps), "Steps didn't round the typed value")
    }

    /// Roadmap #28: BAKE › Settings opens with ⌘, and its switches work. (The UI test shares the app's
    /// real settings, so it puts the switch back.)
    @MainActor
    func testSettingsOpenAndTheirSwitchesFlip() {
        let app = launchWithNewDocument()
        app.typeKey(",", modifierFlags: .command)
        let animate = app.descendants(matching: .any)["settings.animateCards"].firstMatch
        XCTAssertTrue(animate.waitForExistence(timeout: 3), "Settings didn't open")
        XCTAssertTrue(app.descendants(matching: .any)["settings.embedWorkflow"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings.outputDevice"].firstMatch.exists)
        let before = animate.value as? Int
        animate.click()
        let deadline = Date().addingTimeInterval(2)
        while (animate.value as? Int) == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertNotEqual(animate.value as? Int, before, "the switch didn't flip")
        animate.click()
    }

    /// Owner report: modulation gave no feedback. Ticking a parameter on Page 2 puts a lane under its
    /// control, before any bake, showing where the modulation can take it.
    @MainActor
    func testTickingAParameterShowsItsModulationLane() {
        let app = launchWithNewDocument()
        addNode("Filters", from: "Effects", in: app)
        let card = app.descendants(matching: .any)["node.filters"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        XCTAssertFalse(card.descendants(matching: .any)["modulation.cutoff"].exists)
        card.buttons["flip"].click()
        // The card body flips over 0.35 s; a click during the turn lands on the moving face.
        Thread.sleep(forTimeInterval: 1)
        let cutoff = card.checkBoxes["Cutoff"]
        XCTAssertTrue(cutoff.waitForExistence(timeout: 2))
        cutoff.click()
        card.buttons["flip"].click()
        Thread.sleep(forTimeInterval: 1)
        let lane = card.descendants(matching: .any)["modulation.cutoff"]
        XCTAssertTrue(lane.waitForExistence(timeout: 2), "no modulation lane under Cutoff")
        XCTAssertTrue(lane.label.contains("can reach"), "lane says \(lane.label)")
    }

    private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if element.value as? String == value { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Product-owner report: settings on Page 2 of every node did nothing.
    @MainActor
    func testPageTwoSettingsChange() {
        let app = launchWithNewDocument()
        addNode("Flanger", from: "Effects", in: app)
        let card = app.descendants(matching: .any)["node.flanger"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.buttons["flip"].click()
        Thread.sleep(forTimeInterval: 1)

        // Feedback Polarity is the card's first menu; its label is a separate text, not the menu's.
        let polarity = card.popUpButtons.element(boundBy: 0)
        XCTAssertTrue(polarity.waitForExistence(timeout: 2))
        polarity.click()
        app.menuItems["Negative"].firstMatch.click()
        XCTAssertEqual(polarity.value as? String, "Negative", "picker did not change")

        let damping = card.sliders["HF Damping"].firstMatch
        XCTAssertLessThan(damping.normalizedSliderPosition, 0.5)
        damping.adjust(toNormalizedSliderPosition: 0.9)
        XCTAssertGreaterThan(damping.normalizedSliderPosition, 0.8, "slider did not change")
    }
}
