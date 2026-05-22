require 'xcodeproj'

project_path = 'pulse.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

views_group = project.main_group.find_subpath(File.join('pulse', 'Views'), true)
[
  'pulse/Views/ProcessRowView.swift',
  'pulse/Views/ProcessListView.swift'
].each do |file_path|
  file_ref = views_group.new_reference(File.basename(file_path))
  target.add_file_references([file_ref])
end

managers_group = project.main_group.find_subpath(File.join('pulse', 'Managers'), true)
[
  'pulse/Managers/ThemeManager.swift'
].each do |file_path|
  file_ref = managers_group.new_reference(File.basename(file_path))
  target.add_file_references([file_ref])
end

project.save
