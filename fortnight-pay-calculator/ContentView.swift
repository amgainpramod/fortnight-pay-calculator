// ContentView.swift
// SwiftUI view with Public Holiday detection and conditional Shift selection

import SwiftUI

// Make Date Identifiable for sheet
extension Date: Identifiable {
    public var id: TimeInterval { timeIntervalSinceReferenceDate }
}

// Day penalty multipliers
private enum DayType: Double {
    case weekday  = 1.0, saturday = 1.5, sunday = 1.75, holiday = 2.5
}

// Shift multipliers
private enum ShiftType: Double, CaseIterable, Identifiable {
    case morning = 1.0, afternoon = 1.125, night = 1.15
    var id: ShiftType { self }
    var label: String {
        switch self {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .night: return "Night"
        }
    }
}

// Public holiday model
private struct Holiday: Decodable { let date: String }

struct ContentView: View {
    @State private var startDate = Date()
    @State private var selectedDates = Set<Date>()
    @State private var shiftSelections = [Date: ShiftType]()
    @State private var baseRateString = ""
    @State private var hoursPerDayString = ""
    @State private var publicHolidays = Set<Date>()
    @State private var activeDate: Date? = nil

    private let calendar = Calendar.current
    private let isoFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; return df
    }()
    private let displayFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateStyle = .medium; return df
    }()

    private var fortnightDates: [Date] {
        let startDay = calendar.startOfDay(for: startDate)
        let weekday = calendar.component(.weekday, from: startDay)
        let daysToSubtract = (weekday == 1 ? 6 : weekday - 2)
        let weekStart = calendar.date(byAdding: .day, value: -daysToSubtract, to: startDay) ?? startDay
        return (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private func loadPublicHolidays() {
        publicHolidays.removeAll()
        let year = calendar.component(.year, from: startDate)
        let years = [year, year + 1]
        let fallback: [Int: [String]] = [
            2025: ["2025-01-01","2025-01-26","2025-04-25","2025-12-25","2025-12-26"],
            2026: ["2026-01-01","2026-01-26","2026-04-25","2026-12-25","2026-12-26"]
        ]
        for y in years {
            fallback[y]?.forEach { ds in
                if let d = isoFormatter.date(from: ds) {
                    publicHolidays.insert(calendar.startOfDay(for: d))
                }
            }
        }
        Task {
            for y in years {
                guard let url = URL(string: "https://date.nager.at/api/v3/PublicHolidays/\(y)/AU") else { continue }
                if let (data, _) = try? await URLSession.shared.data(from: url), let list = try? JSONDecoder().decode([Holiday].self, from: data) {
                    let dates = list.compactMap { isoFormatter.date(from: $0.date).map { calendar.startOfDay(for: $0) } }
                    await MainActor.run { publicHolidays.formUnion(dates) }
                }
            }
        }
    }

    private var totalPay: Double {
        let rate = Double(baseRateString) ?? 0
        let hours = Double(hoursPerDayString) ?? 0
        return selectedDates.reduce(0) { sum, date in
            let ds = calendar.startOfDay(for: date)
            let wd = calendar.component(.weekday, from: ds)
            let isPH = publicHolidays.contains(ds)
            let isWeekend = (wd == 1 || wd == 7)
            let dayMult = isPH ? DayType.holiday.rawValue : (wd == 7 ? DayType.saturday.rawValue : (wd == 1 ? DayType.sunday.rawValue : DayType.weekday.rawValue))
            let shiftMult = (!isPH && !isWeekend) ? (shiftSelections[ds]?.rawValue ?? ShiftType.morning.rawValue) : 1.0
            return sum + rate * hours * dayMult * shiftMult
        }
    }

    var body: some View {
        // Wrap in ScrollView so content can scroll above keyboard
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: "dollarsign.circle").font(.system(size: 36)).foregroundColor(.accentColor)
                    VStack(spacing: 12) {
                        InputRow(label: "Base Rate (AUD/hr)", text: $baseRateString)
                            .keyboardType(.decimalPad)
                            .onChange(of: baseRateString) { val in
                                let filtered = val.filter { "0123456789.".contains($0) }
                                let dots = filtered.filter { $0 == "." }.count
                                if filtered != val || dots > 1 {
                                    baseRateString = String(filtered.prefix { $0 != "." || dots <= 1 })
                                }
                            }
                        InputRow(label: "Hours per Day", text: $hoursPerDayString)
                            .keyboardType(.decimalPad)
                            .onChange(of: hoursPerDayString) { val in
                                let filtered = val.filter { "0123456789.".contains($0) }
                                let dots = filtered.filter { $0 == "." }.count
                                if filtered != val || dots > 1 {
                                    hoursPerDayString = String(filtered.prefix { $0 != "." || dots <= 1 })
                                }
                            }
                    }
                }
                .padding(.horizontal)
                .onAppear(perform: loadPublicHolidays)

                // Fortnight start picker
                DatePicker("Fortnight Start", selection: $startDate, displayedComponents: .date)
                    .datePickerStyle(GraphicalDatePickerStyle())
                    .padding(.horizontal)
                    .onChange(of: startDate) { _ in loadPublicHolidays() }

                let columns = Array(repeating: GridItem(.flexible()), count: 7)
                // Calculate offset to align first date under correct weekday
                let firstWeekdayIndex = calendar.component(.weekday, from: fortnightDates.first!) - calendar.firstWeekday
                let offset = (firstWeekdayIndex + 7) % 7
                let totalCells = offset + fortnightDates.count
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(0..<totalCells, id: \.self) { idx in
                        if idx < offset {
                            // Empty placeholder
                            Color.clear
                                .frame(minHeight: 40)
                        } else {
                            let date = fortnightDates[idx - offset]
                            let ds = calendar.startOfDay(for: date)
                            let wd = calendar.component(.weekday, from: ds)
                            let isPH = publicHolidays.contains(ds)
                            let isWeekend = (wd == 1 || wd == 7)
                            let isSel = selectedDates.contains(ds)
                            let bg = isSel ? Color.blue.opacity(0.7)
                                : isPH ? Color.red.opacity(0.3)
                                : isWeekend ? Color.gray.opacity(0.2)
                                : Color.clear
                            Text("\(calendar.component(.day, from: ds))")
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(bg).cornerRadius(8)
                                .onTapGesture {
                                    if selectedDates.contains(ds) {
                                        selectedDates.remove(ds)
                                        shiftSelections.removeValue(forKey: ds)
                                    } else {
                                        selectedDates.insert(ds)
                                        shiftSelections[ds] = .morning
                                        // Only prompt shift selection for weekdays
                                        let wd2 = calendar.component(.weekday, from: ds)
                                        let isPH2 = publicHolidays.contains(ds)
                                        let isWeekend2 = (wd2 == 1 || wd2 == 7)
                                        if !isPH2 && !isWeekend2 {
                                            activeDate = ds
                                        }
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    Text("Selected: \(selectedDates.count) days")
                    Text(String(format: "Gross Earnings: $%.2f", totalPay))
                        .font(.title2).bold()
                    Button("Reset") {
                        selectedDates.removeAll(); shiftSelections.removeAll(); baseRateString=""; hoursPerDayString=""; startDate=Date(); activeDate=nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            // add extra bottom padding to allow keyboard visibility
            .padding(.bottom, 300)
        }
    .sheet(item: $activeDate) { date in
        VStack(spacing: 16) {
            Text("Select Shift for \(displayFormatter.string(from: date))").font(.headline)
            Picker("Shift", selection: Binding(
                get: { shiftSelections[date] ?? .morning },
                set: { shiftSelections[date] = $0 }
            )) {
                ForEach(ShiftType.allCases) { st in Text(st.label).tag(st) }
            }
            .pickerStyle(SegmentedPickerStyle()).padding()
            Button("Done") { activeDate = nil }.buttonStyle(.borderedProminent)
        }
        .padding()
    }
        .sheet(item: $activeDate) { date in
            VStack(spacing: 16) {
                Text("Select Shift for \(displayFormatter.string(from: date))").font(.headline)
                Picker("Shift", selection: Binding(
                    get: { shiftSelections[date] ?? .morning },
                    set: { shiftSelections[date] = $0 }
                )) {
                    ForEach(ShiftType.allCases) { st in Text(st.label).tag(st) }
                }
                .pickerStyle(SegmentedPickerStyle()).padding()
                Button("Done") { activeDate = nil }.buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

private struct InputRow: View {
    let label: String
    @Binding var text: String
    var body: some View {
        HStack { Text(label); Spacer(); TextField("", text: $text).multilineTextAlignment(.trailing).frame(width: 80) }
        .padding(8).background(Color(UIColor.secondarySystemBackground)).cornerRadius(8)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
