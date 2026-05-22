require 'xcodeproj'
project_path = 'mac-monitor.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

# Find the Views group
app_group = project.main_group.children.find { |g| g.display_name == 'mac-monitor' || g.name == 'mac-monitor' }
views_group = app_group.children.find { |g| g.display_name == 'Views' || g.name == 'Views' }

unless views_group
  puts "Could not find Views group"
  exit 1
end

# Check if file is already there
existing_file = views_group.files.find { |f| f.path == 'PopoverView.swift' || f.name == 'PopoverView.swift' }
if existing_file
  puts "File already in project"
  exit 0
end

file_ref = views_group.new_file('PopoverView.swift')
target.source_build_phase.add_file_reference(file_ref)

project.save
puts "Successfully added PopoverView.swift to project"
