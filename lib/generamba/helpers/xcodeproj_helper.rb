module Generamba
  # Provides a number of helper methods for working with xcodeproj gem
  class XcodeprojHelper
    # Returns a PBXProject class for a given name
    # @param project_name [String] The name of the project file
    #
    # @return [Xcodeproj::Project]
    def self.obtain_project(project_name)
      Xcodeproj::Project.open(project_name)
    end

    # Adds a provided file to a specific Project and Target
    # @param project [Xcodeproj::Project] The target xcodeproj file
    # @param targets_name [String] Array of targets name
    # @param group_path [Pathname] The Xcode group path for current file
    # @param dir_path [Pathname] The directory path for current file
    # @param file_group_path [String] Directory path
    # @param file_name [String] Current file name
    # @param file_is_resource [TrueClass or FalseClass] If true then file is resource
    #
    # @return [void]
    def self.add_file_to_project_and_targets(project, targets_name, group_path, dir_path, file_group_path, file_name, root_path, file_is_resource = false)
      
      if root_path
          file_path = root_path
      else
          file_path = dir_path
          file_path = file_path.join(file_group_path) if file_group_path
      end

      file_path = file_path.join(file_name) if file_name

      module_group = self.retrieve_group_or_create_if_needed(group_path, dir_path, file_group_path, project, true, root_path)

      # Handle PBXFileSystemSynchronizedRootGroup (folder-based projects)
      if module_group.class.to_s.include?('PBXFileSystemSynchronizedRootGroup')
        # For folder-based projects, we add files directly to the target without groups
        # The file system structure will be automatically reflected in Xcode
        absolute_file_path = File.absolute_path(file_path)
        project_dir = File.dirname(project.path)

        begin
          relative_path = Pathname.new(absolute_file_path).relative_path_from(Pathname.new(project_dir))
          xcode_file = project.main_group.find_file_by_path(relative_path.to_s) ||
                       project.main_group.new_reference(absolute_file_path)
        rescue ArgumentError
          # If relative path calculation fails, just use absolute path
          xcode_file = project.main_group.new_reference(absolute_file_path)
        end
      else
        xcode_file = module_group.new_file(File.absolute_path(file_path))
      end

      targets_name.each do |target|
        xcode_target = obtain_target(target, project)

        if file_is_resource || self.is_bundle_resource?(file_name)
          xcode_target.add_resources([xcode_file])
        elsif self.is_compile_source?(file_name)
          xcode_target.add_file_references([xcode_file])
        end
      end
    end

    # Adds a provided directory to a specific Project
    # @param project [Xcodeproj::Project] The target xcodeproj file
    # @param group_path [Pathname] The Xcode group path for current directory
    # @param dir_path [Pathname] The directory path for current directory
    # @param directory_name [String] Current directory name
    #
    # @return [void]
    def self.add_group_to_project(project, group_path, dir_path, directory_name, group_is_logical)
      self.retrieve_group_or_create_if_needed(group_path, dir_path, directory_name, project, true, group_is_logical)
    end

    # File is a compiled source
    # @param file_name [String] String of file name
    #
    # @return [TrueClass or FalseClass]
    def self.is_compile_source?(file_name)
      File.extname(file_name) == '.m' || File.extname(file_name) == '.swift' || File.extname(file_name) == '.mm'
    end

    # File is a resource
    # @param resource_name [String] String of resource name
    #
    # @return [TrueClass or FalseClass]
    def self.is_bundle_resource?(resource_name)
      File.extname(resource_name) == '.xib' || File.extname(resource_name) == '.storyboard'
    end

    # Recursively clears children of the given group
    # @param project [Xcodeproj::Project] The working Xcode project file
    # @param group_path [Pathname] The full group path
    #
    # @return [Void]
    def self.clear_group(project, targets_name, group_path, group_is_logical)
      module_group = self.retrieve_group_or_create_if_needed(group_path, nil, nil, project, false, group_is_logical)
      return unless module_group

      # Handle PBXFileSystemSynchronizedRootGroup (folder-based projects)
      if module_group.class.to_s.include?('PBXFileSystemSynchronizedRootGroup')
        # For folder-based projects, we don't need to clear groups manually
        # The file system structure is automatically synced
        return
      end

      files_path = self.files_path_from_group(module_group, project)
      return unless files_path

      files_path.each do |file_path|
        self.remove_file_by_file_path(file_path, targets_name, project)
      end

      # Only clear if it's a traditional PBXGroup
      if module_group.respond_to?(:clear)
        module_group.clear
      end
    end

    # Finds a group in a xcodeproj file with a given path
    # @param project [Xcodeproj::Project] The working Xcode project file
    # @param group_path [Pathname] The full group path
    #
    # @return [TrueClass or FalseClass]
    def self.module_with_group_path_already_exists(project, group_path, group_is_logical)
      # For projects that might have folder-based components, check filesystem first
      project_dir = File.dirname(project.path)
      module_dir = File.join(project_dir, group_path.to_s)

      # If the directory actually exists on filesystem, the module exists
      if Dir.exist?(module_dir)
        return true
      end

      # For traditional projects, use the original logic
      module_group = self.retrieve_group_or_create_if_needed(group_path, nil, nil, project, false, group_is_logical)

      # If we get a PBXFileSystemSynchronizedRootGroup back, it means we hit folder-based structure
      # In this case, the filesystem check above is authoritative
      if module_group && module_group.class.to_s.include?('PBXFileSystemSynchronizedRootGroup')
        return false  # We already checked filesystem above, so module doesn't exist
      end

      # For traditional groups, check if we got a valid group back
      module_group.nil? ? false : true
    end

    private

    # Finds or creates a group in a xcodeproj file with a given path
    # @param group_path [Pathname] The Xcode group path for module
    # @param dir_path [Pathname] The directory path for module
    # @param file_group_path [String] Directory path
    # @param project [Xcodeproj::Project] The working Xcode project file
    # @param create_group_if_not_exists [TrueClass or FalseClass] If true nonexistent group will be created
    #
    # @return [PBXGroup]
    def self.retrieve_group_or_create_if_needed(group_path, dir_path, file_group_path, project, create_group_if_not_exists, group_is_logical = false)
      group_names = path_names_from_path(group_path)
      group_components_count = group_names.count
      group_names += path_names_from_path(file_group_path) if file_group_path

      # Check if project uses PBXFileSystemSynchronizedRootGroup (folder-based structure)
      main_group_class = project.main_group.class.to_s
      if main_group_class.include?('PBXFileSystemSynchronizedRootGroup')
        # For folder-based projects, return the main_group directly
        # We can't create traditional groups in this structure
        return project.main_group
      end

      # Handle traditional PBXGroup structure
      final_group = project.main_group

      group_names.each_with_index do |group_name, index|
        # Double-check if we're dealing with PBXFileSystemSynchronizedRootGroup
        if final_group.class.to_s.include?('PBXFileSystemSynchronizedRootGroup')
          return final_group
        end

        if final_group.respond_to?(:[])
          next_group = final_group[group_name]
        else
          next_group = nil
        end

        unless next_group
          return nil unless create_group_if_not_exists

          # Final safety check before calling new_group
          unless final_group.respond_to?(:new_group)
            return final_group
          end

          if group_path != dir_path && index == group_components_count-1
              next_group = group_is_logical ? final_group.new_group(group_name) : final_group.new_group(group_name, dir_path, :project)
          else
          next_group = group_is_logical ?  final_group.new_group(group_name) : final_group.new_group(group_name, group_name)
          end
        end

        final_group = next_group
      end

      final_group
    end

    # Returns an AbstractTarget class for a given name
    # @param target_name [String] The name of the target
    # @param project [Xcodeproj::Project] The target xcodeproj file
    #
    # @return [Xcodeproj::AbstractTarget]
    def self.obtain_target(target_name, project)
      project.targets.each do |target|
        return target if target.name == target_name
      end

      error_description = "Cannot find a target with name #{target_name} in Xcode project".red
      raise StandardError, error_description
    end

    # Splits the provided Xcode path to an array of separate paths
    # @param path The full group or file path
    #
    # @return [[String]]
    def self.path_names_from_path(path)
      path.to_s.split('/')
    end

    # Remove build file from target build phase
    # @param file_path [String] The path of the file
    # @param targets_name [String] Array of targets
    # @param project [Xcodeproj::Project] The target xcodeproj file
    #
    # @return [Void]
    def self.remove_file_by_file_path(file_path, targets_name, project)
      file_names = path_names_from_path(file_path)

      build_phases = nil

      if self.is_compile_source?(file_names.last)
        build_phases = self.build_phases_from_targets(targets_name, project)
      elsif self.is_bundle_resource?(file_names.last)
        build_phases = self.resources_build_phase_from_targets(targets_name, project)
      end

      self.remove_file_from_build_phases(file_path, build_phases)
    end

    def self.remove_file_from_build_phases(file_path, build_phases)
      return if build_phases.nil?

      build_phases.each do |build_phase|
        build_phase.files.each do |build_file|
          next if build_file.nil? || build_file.file_ref.nil?

          build_file_path = self.configure_file_ref_path(build_file.file_ref)

          if build_file_path == file_path
            build_phase.remove_build_file(build_file)
          end
        end
      end
    end

    # Find and return target build phases
    # @param targets_name [String] Array of targets
    # @param project [Xcodeproj::Project] The target xcodeproj file
    #
    # @return [[PBXSourcesBuildPhase]]
    def self.build_phases_from_targets(targets_name, project)
      build_phases = []

      targets_name.each do |target_name|
        xcode_target = self.obtain_target(target_name, project)
        xcode_target.build_phases.each do |build_phase|
          if build_phase.isa == 'PBXSourcesBuildPhase'
            build_phases.push(build_phase)
          end
        end
      end

      build_phases
    end

    # Find and return target resources build phase
    # @param targets_name [String] Array of targets
    # @param project [Xcodeproj::Project] The target xcodeproj file
    #
    # @return [[PBXResourcesBuildPhase]]
    def self.resources_build_phase_from_targets(targets_name, project)
      resource_build_phase = []

      targets_name.each do |target_name|
        xcode_target = self.obtain_target(target_name, project)
        resource_build_phase.push(xcode_target.resources_build_phase)
      end

      resource_build_phase
    end

    # Get configure file full path
    # @param file_ref [PBXFileReference] Build file
    #
    # @return [String]
    def self.configure_file_ref_path(file_ref)
      build_file_ref_path = file_ref.hierarchy_path.to_s
      build_file_ref_path[0] = ''

      build_file_ref_path
    end

    # Get all files path from group path
    # @param module_group [PBXGroup] The module group
    # @param project [Xcodeproj::Project] The target xcodeproj file
    #
    # @return [[String]]
    def self.files_path_from_group(module_group, _project)
      files_path = []

      # Handle PBXFileSystemSynchronizedRootGroup compatibility
      if module_group.class.to_s.include?('PBXFileSystemSynchronizedRootGroup')
        # For folder-based projects, we can't traverse recursive_children
        # Return empty array since folder-based projects handle file cleanup differently
        return files_path
      end

      # Handle traditional PBXGroup structure
      if module_group.respond_to?(:recursive_children)
        module_group.recursive_children.each do |file_ref|
          if file_ref.isa == 'PBXFileReference'
            file_ref_path = configure_file_ref_path(file_ref)
            files_path.push(file_ref_path)
          end
        end
      end

      files_path
    end
  end
end
