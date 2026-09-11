import Foundation

// One recipe per file under Recipes/. Each is a function `(URL) throws -> Void` that writes what it makes into the
// directory it is given and prints what it did. `all` runs every recipe in order.
let recipes: [(name: String, run: (URL) throws -> Void)] = [
    ("open-edit-save", openEditSave),
    ("report-from-scratch", reportFromScratch),
    ("convert-a-folder", convertAFolder),
    ("numbers-to-excel", numbersToExcel),
    ("sum-across-workbooks", sumAcrossWorkbooks),
    ("keep-the-macros", keepTheMacros),
    ("write-row-by-row", writeRowByRow),
    ("legacy-csv-to-excel", legacyCSVToExcel),
    ("inspect-before-reading", inspectBeforeReading),
    ("only-some-formats", onlySomeFormats),
    ("validation-and-formatting", validationAndFormatting),
    ("pictures-and-charts", picturesAndCharts),
    ("errors-and-warnings", errorsAndWarnings),
]

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2 else {
    let names = recipes.map(\.name).joined(separator: "\n  ")
    FileHandle.standardError.write(Data("usage: swiftsheets-examples <recipe|all> <directory>\nrecipes:\n  \(names)\n".utf8))
    exit(2)
}
let wanted = arguments.first!
let directory = URL(filePath: arguments.last!)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let chosen = wanted == "all" ? recipes : recipes.filter { $0.name == wanted }
guard !chosen.isEmpty else { FileHandle.standardError.write(Data("no recipe named \(wanted)\n".utf8)); exit(2) }
for recipe in chosen {
    print("== \(recipe.name)")
    try recipe.run(directory)
}
