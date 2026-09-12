import XCTest

final class TrackGymUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_appLaunchesAndShowsRootView() throws {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.firstMatch.exists, "Tab bar should be visible after app launch")
        for tab in ["Übungen", "Meine Trainings", "Fortschritt"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists)
        }
    }

    @MainActor
    func test_finishingUntouchedWorkoutDoesNotCreateHistory() {
        let app = launchApp()
        createPlan(in: app, exercises: ["Bankdrücken"])
        app.buttons["UI Training starten"].tap()
        app.buttons["Beenden"].tap()
        app.alerts.buttons["Beenden & speichern"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Fortschritt"].tap()
        XCTAssertTrue(app.staticTexts["Keine Daten vorhanden"].exists)
    }

    @MainActor
    func test_emptySetMustBeCorrectedBeforeSaving() {
        let app = launchApp()
        createPlan(in: app, exercises: ["Bankdrücken"])
        app.buttons["UI Training starten"].tap()
        app.buttons["Bankdrücken speichern"].tap()

        XCTAssertTrue(app.alerts["Training konnte nicht gespeichert werden"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()
        replaceText(in: app.textFields["reps-Bankdrücken-1"], with: "8")
        app.buttons["Bankdrücken speichern"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Fortschritt"].tap()
        XCTAssertTrue(app.buttons["Bankdrücken"].exists)
        XCTAssertFalse(app.staticTexts["Keine Daten vorhanden"].exists)
    }

    @MainActor
    func test_partialSaveKeepsOtherEditedExerciseWhenFinishing() {
        let app = launchApp()
        createPlan(in: app, exercises: ["Bankdrücken", "Brustpresse"])
        app.buttons["UI Training starten"].tap()
        replaceText(in: app.textFields["reps-Brustpresse-1"], with: "10")
        replaceText(in: app.textFields["reps-Bankdrücken-1"], with: "8")
        app.buttons["Bankdrücken speichern"].tap()
        app.buttons["Beenden"].tap()
        app.alerts.buttons["Beenden & speichern"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Fortschritt"].tap()
        XCTAssertTrue(app.buttons["Bankdrücken"].exists)
        XCTAssertTrue(app.buttons["Brustpresse"].exists, "A partial save must not lose the edited state of the remaining exercise")
    }

    @MainActor
    func test_cancelPreservesOnlyExplicitlySavedExercises() {
        let app = launchApp()
        createPlan(in: app, exercises: ["Bankdrücken", "Brustpresse"])
        app.buttons["UI Training starten"].tap()
        replaceText(in: app.textFields["reps-Bankdrücken-1"], with: "8")
        app.buttons["Bankdrücken speichern"].tap()
        replaceText(in: app.textFields["reps-Brustpresse-1"], with: "10")
        app.buttons["Abbrechen"].tap()
        app.alerts.buttons["Training abbrechen"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Fortschritt"].tap()
        XCTAssertTrue(app.buttons["Bankdrücken"].exists)
        XCTAssertFalse(app.buttons["Brustpresse"].exists)
    }

    @MainActor
    func test_deletingCustomExercisePreservesProgressAndEmptyPlanHistory() {
        let app = launchApp()
        let exerciseName = "UI Testübung"
        app.tabBars.buttons["Übungen"].tap()
        app.buttons["Übung hinzufügen"].tap()
        replaceText(in: app.textFields["Name der Übung"], with: exerciseName)
        app.buttons["Speichern"].tap()

        app.tabBars.buttons["Meine Trainings"].tap()
        createPlan(in: app, exercises: [exerciseName])
        app.buttons["UI Training starten"].tap()
        replaceText(in: app.textFields["reps-\(exerciseName)-1"], with: "8")
        app.buttons["\(exerciseName) speichern"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

        // Also exercise the selected-progress state when its exercise is deleted.
        app.tabBars.buttons["Fortschritt"].tap()
        XCTAssertTrue(app.buttons[exerciseName].waitForExistence(timeout: 5))
        app.buttons[exerciseName].tap()
        app.tabBars.buttons["Übungen"].tap()
        replaceText(in: app.searchFields.firstMatch, with: exerciseName)
        let exerciseRow = app.cells.containing(.staticText, identifier: exerciseName).firstMatch
        XCTAssertTrue(exerciseRow.waitForExistence(timeout: 5))
        exerciseRow.swipeLeft()
        app.buttons["Löschen"].tap()
        XCTAssertTrue(app.buttons["Übung löschen"].waitForExistence(timeout: 5))
        app.buttons["Übung löschen"].tap()
        XCTAssertTrue(app.staticTexts["Keine Übungen gefunden"].waitForExistence(timeout: 5))
        let closeSearch = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "close")).firstMatch
        if closeSearch.exists { closeSearch.tap() }

        app.tabBars.buttons["Fortschritt"].tap()
        XCTAssertTrue(app.buttons["Gesamt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Keine Daten vorhanden"].exists)
        XCTAssertFalse(app.buttons[exerciseName].exists)
        let trainingCount = app.cells.containing(.staticText, identifier: "Trainings").firstMatch
        XCTAssertTrue(trainingCount.waitForExistence(timeout: 5))
        XCTAssertTrue(trainingCount.staticTexts["1"].exists)

        app.tabBars.buttons["Meine Trainings"].tap()
        app.buttons["UI Training"].tap()
        XCTAssertTrue(app.staticTexts["Keine Übungen"].waitForExistence(timeout: 5))
        app.buttons["Trainingshistorie anzeigen"].tap()
        XCTAssertTrue(app.navigationBars["Trainingshistorie"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Noch kein Training für diesen Plan absolviert."].exists)
        let historyRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1 Übungen")).firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        historyRow.tap()
        XCTAssertTrue(app.staticTexts["Unbekannte Übung"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "× 8 Wdh")).firstMatch.exists)
    }

    @MainActor
    func test_catalogEmptySearchCanResetSearchAndBothFilters() {
        let app = launchApp()
        app.tabBars.buttons["Übungen"].tap()
        app.buttons["Arme"].tap()
        app.buttons["Freihantel"].tap()
        replaceText(in: app.searchFields.firstMatch, with: "UI Keine passende Übung")
        app.searchFields.firstMatch.typeText("\n")

        XCTAssertTrue(app.staticTexts["Keine Übungen gefunden"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Filter zurücksetzen"].exists)
        app.buttons["Filter zurücksetzen"].tap()

        XCTAssertFalse(app.staticTexts["Keine Übungen gefunden"].exists)
        XCTAssertFalse(app.buttons["Filter zurücksetzen"].exists)
        XCTAssertFalse(app.buttons["Arme"].isSelected)
        XCTAssertFalse(app.buttons["Freihantel"].isSelected)
        let allFilters = app.buttons.matching(identifier: "Alle").allElementsBoundByIndex
        XCTAssertEqual(allFilters.count, 2)
        XCTAssertTrue(allFilters.allSatisfy(\.isSelected))
        let searchField = app.searchFields.firstMatch
        let searchValue = searchField.value as? String ?? ""
        XCTAssertTrue(searchValue.isEmpty || searchValue == searchField.placeholderValue)
        XCTAssertTrue(app.staticTexts["Bizepsmaschine"].waitForExistence(timeout: 5), "Reset must restore exercises excluded by the equipment filter")
    }

    @MainActor
    func test_finishingDiscardsExerciseWhoseLastSetWasDeleted() {
        let app = launchApp()
        createPlan(in: app, exercises: ["Bankdrücken", "Brustpresse"])
        app.buttons["UI Training starten"].tap()
        let setRow = app.cells.containing(.textField, identifier: "reps-Brustpresse-1").firstMatch
        XCTAssertTrue(setRow.waitForExistence(timeout: 5))
        setRow.swipeLeft()
        // A full swipe commits SwiftUI's onDelete action immediately.
        if app.textFields["reps-Brustpresse-1"].exists {
            app.buttons.matching(NSPredicate(format: "label IN %@", ["Löschen", "Delete"])).firstMatch.tap()
        }
        XCTAssertFalse(app.textFields["reps-Brustpresse-1"].exists)
        replaceText(in: app.textFields["reps-Bankdrücken-1"], with: "8")
        app.buttons["Beenden"].tap()
        app.alerts.buttons["Beenden & speichern"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Fortschritt"].tap()
        XCTAssertTrue(app.buttons["Bankdrücken"].exists)
        XCTAssertFalse(app.buttons["Brustpresse"].exists)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Each test gets a fresh in-memory store, leaving simulator data intact.
        app.launchArguments = ["-uiTesting", "-weightUnit", "kg", "-restTimerDuration", "0", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func createPlan(in app: XCUIApplication, exercises: [String]) {
        app.buttons["Plan erstellen"].firstMatch.tap()
        app.textFields["z.B. Push, Pull, Legs"].tap()
        app.textFields["z.B. Push, Pull, Legs"].typeText("UI Training")
        app.buttons["Übung hinzufügen"].tap()
        for exercise in exercises {
            replaceText(in: app.searchFields.firstMatch, with: exercise)
            app.staticTexts[exercise].firstMatch.tap()
        }
        // iOS 26 hides the picker toolbar while its search mode is active.
        let closeSearch = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "close")).firstMatch
        if closeSearch.exists { closeSearch.tap() }
        XCTAssertTrue(app.buttons["Fertig (\(exercises.count))"].waitForExistence(timeout: 5))
        app.buttons["Fertig (\(exercises.count))"].tap()
        app.buttons["Speichern"].tap()
        XCTAssertTrue(app.buttons["UI Training starten"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = field.value as? String ?? ""
        let count = current == field.placeholderValue ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text)
    }
}
