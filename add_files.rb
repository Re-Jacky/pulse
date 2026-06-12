require 'xcodeproj'

project_path = 'pulse.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

file_paths = ARGV

file_paths.each do |file_path|
  # Determine group path
  dir = File.dirname(file_path)
  group_name = dir.sub(%r{^pulse/}, '').sub(%r{^pulseTests$}, 'pulseTests')

  group = if group_name == 'pulseTests'
    project.main_group.find_subpath('pulseTests', true)
  elsif group_name.start_with?('Views')
    project.main_group.find_subpath(File.join('pulse', 'Views'), true)
  elsif group_name.start_with?('Managers')
    project.main_group.find_subpath(File.join('pulse', 'Managers'), true)
  else
    project.main_group
  end

  # Skip if file already exists
  existing = group.children.find { |c| c.path == File.basename(file_path) || c.real_path.to_s.end_with?(file_path) }
  next if existing

  file_ref = group.new_reference(File.basename(file_path))
  target.add_file_references([file_ref])
end

project.save
