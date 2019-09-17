#!/usr/bin/ruby

require 'xcodeproj'
require 'set'
require 'open3'
require 'digest'
require 'fileutils'
require 'json'

$abc_filePathDict = {}
$abc_headerMd5Dict = {}
$abc_fileContentMd5Dict = {}
$abc_fileHeaderMd5Dict = {}
$abc_workspacePath = ''
$abc_globalCachePath = Dir.home + '/auto_build_cache'
$abc_cacheProductSearchPath = Dir.pwd + '/auto_build_cache_products'
$abc_maxCacheCount = 1000

def copySafe(src, dst)
    return unless File.exist? src
    FileUtils.remove_entry dst if File.exist? dst
    FileUtils.mkdir_p(File.dirname(dst)) unless File.exist? File.dirname(dst)
    if File.file? src
        # copy content, dst is not a symlink
        FileUtils.cp(src, dst)
    else
        fileArray = Dir.glob(src + '/**/*')
        fileArray.delete_if { | file | !File.file? file }
        fileArray.each do | file |
            copySafe(file, file.gsub(src, dst))
        end
    end
end

def getImportHeaderArrayForFile(file)
    resultSet = Set.new
    File.open(file, "r:UTF-8") do | f |
        f.each_line do | line |
            begin
                line = line.gsub(/\/\/.*/, '')
                scanArray = line.scan(/(?:^|[\r\n])\s*?#(?:import|include).*?([^\"\/\s<>]+\.hp?p?)\s*[\">]/)
                if scanArray
                    scanArray.flatten.each do | result |
                        resultSet.add(result)
                    end
                end
            rescue
                next
            end
        end
    end
    return resultSet.sort
end

def getMd5ForContent(content)
    # avoid temp file
    content = content.gsub(Dir.pwd, '.')
    return Digest::MD5.hexdigest(content)
end

def getMd5ForFile(file)
    fileContentMd5Dict = $abc_fileContentMd5Dict
    fileContentMd5 = ''
    if fileContentMd5Dict.has_key? file
        fileContentMd5 = fileContentMd5Dict[file]
    else
        fileContent = File.read(file)
        if file.end_with? '.xcconfig'
            # do not need change md5 if search path change
            fileContent = fileContent.gsub(/FRAMEWORK_SEARCH_PATHS = .*\n/, '')
            fileContent = fileContent.gsub(/HEADER_SEARCH_PATHS = .*\n/, '')
            fileContent = fileContent.gsub(/LIBRARY_SEARCH_PATHS = .*\n/, '')
        end
        fileContentMd5 = getMd5ForContent(fileContent)
        fileContentMd5Dict[file] = fileContentMd5
    end
    return fileContentMd5
end

def getHeaderMd5ForFile(file, headerStack)

    filePathDict = $abc_filePathDict
    headerMd5Dict = $abc_headerMd5Dict
    fileContentMd5Dict = $abc_fileContentMd5Dict
    fileHeaderMd5Dict = $abc_fileHeaderMd5Dict

    if ! filePathDict.has_key? File.basename(file)
        return getMd5ForFile(file)
    end

    if fileHeaderMd5Dict.has_key? file
        return fileHeaderMd5Dict[file]
    end

    fileContentMd5 = getMd5ForFile(file)
    md5Array = [fileContentMd5]
    headerArray = getImportHeaderArrayForFile(file)
    headerArray.each do | header |
        if headerMd5Dict.has_key? header
            md5Array.push(headerMd5Dict[header])
        elsif (filePathDict.has_key? header)
            next if (headerStack.include? header)
            headerMd5Array = []
            filePathDict[header].each do | headerFile |
                if fileHeaderMd5Dict.has_key? headerFile
                    md5Array.push(fileHeaderMd5Dict[headerFile])
                    next
                end
                headerStack.push(header)
                headerFileMd5 = getHeaderMd5ForFile(headerFile, headerStack)
                headerStack.pop()
                headerMd5Array.push(headerFileMd5)
            end
            headerMd5Dict[header] = getMd5ForContent(headerMd5Array.sort.join("\n"))
            if headerMd5Array.size > 0
                md5Array.push(headerMd5Dict[header])
            end
        end
    end
    if md5Array.size > 1
        fileHeaderMd5Dict[file] = getMd5ForContent(md5Array.sort.join("\n"))
    else
        fileHeaderMd5Dict[file] = md5Array[0]
    end
    return fileHeaderMd5Dict[file]
end

def isSourceCodeFile(file)
    return ['h', 'm', 'c', 'hpp', 'cpp', 'mm', 'pch'].include? file.split('.')[-1]
end

def getAllFileArrayInDir(dir)
    fileArray = Dir.glob(dir + "/**/*")
    fileArray.delete_if { | file | !File.file? file }
    fileArray.delete_if { | file | file.include?('/.git/') }
    fileArray.delete_if { | file | file.end_with?('.log') }
    return fileArray
end

def getHeaderMd5ArrayForFileDirArray(fileDirArray)
    md5Array = []
    fileDirArray.each do | fileDir |
        fileArray = getAllFileArrayInDir(fileDir)
        fileArray.each do | file |
            md5Array.push(file + ' md5 = ' + getMd5ForFile(file))
            if isSourceCodeFile(file)
                headerMd5 = getHeaderMd5ForFile(file, [File.basename(file)])
                if headerMd5 != getMd5ForFile(file)
                    md5Array.push(file + ' headerMd5 = ' + headerMd5)
                end
            end
        end
    end
    return md5Array
end

def runCmd(cmd)
    startTime = Time.now
    puts cmd
    stdout, stderr, status = Open3.capture3(cmd)
    puts 'cmd take time ' + (Time.now - startTime).to_s
    return stdout, stderr, status
end

def getBundleTargetName(target)
    matchResult = target.name.match(/^(.+)-\1$/)
    if matchResult
        return matchResult[1]
    end
    return ''
end

def getFileDirArrayForTarget(target)
    bundleTargetName = ''
    if target.product_type == 'com.apple.product-type.bundle'
        bundleTargetName = getBundleTargetName(target)
    end
    fileArray = []
    target.frameworks_build_phase.files.each do | file |
        fileArray.push(file.file_ref.real_path.to_s)
    end
    target.headers_build_phase.files.each do | file |
        fileArray.push(file.file_ref.real_path.to_s)
    end
    target.resources_build_phase.files.each do | file |
        fileArray.push(file.file_ref.real_path.to_s)
    end
    target.source_build_phase.files.each do | file |
        fileArray.push(file.file_ref.real_path.to_s)
    end

    fileDirSet = Set.new
    fileArray.each do | file |
        next unless File.exist? file
        fileDir = ''
        if File.file? file
            fileDir = File.dirname(file)
        else
            fileDir = file
        end
        fileDir = fileDir.gsub(Dir.pwd, '.')
        if fileDir.include?('/' + target.name + '/')
            fileDir = fileDir.split('/' + target.name + '/')[0] + '/' + target.name
            fileDirSet.add(fileDir)
        elsif bundleTargetName.size > 0 and fileDir.include?('/' + bundleTargetName + '/')
            fileDir = fileDir.split('/' + bundleTargetName + '/')[0] + '/' + bundleTargetName
            fileDirSet.add(fileDir)
        elsif fileDir.include?('/' + target.name.split('-')[0] + '/')
            fileDir = fileDir.split('/' + target.name.split('-')[0] + '/')[0] + '/' + target.name.split('-')[0]
            fileDirSet.add(fileDir)
        else
            fileDirSet.add(fileDir)
        end
    end
    return fileDirSet.sort
end

def getWorkspacePath
    dirArray = Dir['*']
    workspacePath = dirArray.detect { |dir|
        dir.end_with? ".xcworkspace"
    }
    return workspacePath if workspacePath
    return ''
end

def getProjectPathArray(workspacePath)
    workspace = Xcodeproj::Workspace::new_from_xcworkspace(workspacePath)
    unless workspace
        puts 'auto_build_cache_error ' + workspacePath + ' not valid'
        return []
    end
    puts 'workspacePath ' + workspacePath
    projectPathArray = []
    workspace.file_references.each do | fileRef |
        projectPathArray.push fileRef.path
    end
    projectPathArray.delete_if { | projectPath | !File.exist? projectPath}
    return projectPathArray
end

def getProjectArray(projectPathArray)
    projectArray = []
    projectPathArray.each do | projectPath |
        buildPath = File.dirname(projectPath) + '/build'
        FileUtils.remove_entry buildPath if File.exist? buildPath
        project = Xcodeproj::Project::open(projectPath)
        if project
            puts project.path.to_s.gsub(Dir.pwd, '.')
            projectArray.push(project)
        end
    end
    return projectArray
end

def getFilePathDict(projectArray)
    filePathDict = {}
    filePathArray = []
    projectArray.each do | project |
        project.files.each do | file |
            filePath = file.real_path.to_s.gsub(Dir.pwd, '.')
            next unless File.exist? filePath
            if File.file? filePath
                filePathArray.push(filePath) if isSourceCodeFile(filePath)
            else
                getAllFileArrayInDir(filePath).each do | filePathInDir |
                    filePathArray.push(filePathInDir) if isSourceCodeFile(filePathInDir)
                end
            end
        end
    end

    filePathArray.each do | filePath | 
        basename = File.basename(filePath)
        unless filePathDict.has_key?(basename)
            filePathDict[basename] = Set.new
        end
        filePathDict[basename].add(filePath)
    end
    return filePathDict
end

def canCacheTarget(target)
    return false unless target.class == Xcodeproj::Project::Object::PBXNativeTarget
    return false if target.name.start_with?('Pods-')
    productName = getProductNameForTarget(target)
    return false if productName.include?('$')
    return false if productName.include?('{')
    result = ((target.product_type == 'com.apple.product-type.library.static') or (target.product_type == 'com.apple.product-type.bundle'))
    return result
end

def getMd5ForTarget(target)
    startTime = Time.now
    buildSettings = target.pretty_print.to_s
    buildSettingsMd5 = getMd5ForContent(buildSettings)
    fileDirArray = getFileDirArrayForTarget(target)
    puts 'md5 directory ' + fileDirArray.join(", ")
    headerMd5Array = getHeaderMd5ArrayForFileDirArray(fileDirArray)
    resultArray = []
    resultArray.push("buildSettingsMd5=" + buildSettingsMd5)
    resultArray = resultArray + headerMd5Array

    resultContent = resultArray.sort.join("\n")
    resultMd5 = getMd5ForContent(resultContent)
    return resultContent, resultMd5
end

def removeTargetFromProjectArray(targetToRemove, projectArray)
    puts 'remove target ' + targetToRemove.name
    projectArray.each do | project |
        project.targets.delete_if { | target | target.name == targetToRemove.name }
        project.targets.each do | target |
            target.dependencies.delete_if { | dependency | dependency.target.name == targetToRemove.name }
        end
    end
    replaceTargetBundle(targetToRemove)
end

def replaceTargetBundle(target)
    return unless target.product_type == 'com.apple.product-type.bundle'
    targetName = getBundleTargetName(target)
    return unless targetName.size > 0
    fileArray = getAllFileArrayInDir('./Pods/Target Support Files')
    fileArray.each do | file |
        content = File.read(file)
        content = content.gsub("${PODS_CONFIGURATION_BUILD_DIR}/" + targetName + "/" + targetName + ".bundle", $abc_cacheProductSearchPath + "/" + targetName + ".bundle") # pod 1.5.3
        content = content.gsub("$PODS_CONFIGURATION_BUILD_DIR/" + targetName + "/" + targetName + ".bundle", $abc_cacheProductSearchPath + "/" + targetName + ".bundle") # pod 1.3.1
        if content.include?($abc_cacheProductSearchPath + "/" + targetName + ".bundle")
            puts 'replace bundle for target ' + targetName + ' in ' + file
            File.write(file, content)
        end
    end
end

def saveProjectArray(projectArray)
    projectArray.each do | project |
        project.save
    end
end

def addLibrarySearchPath()
    fileArray = getAllFileArrayInDir('./')
    fileArray.each do | file |
        if file.end_with?('.xcconfig')
            content = File.read(file)
            libraryLine = content[/LIBRARY_SEARCH_PATHS.*/]
            if (libraryLine) and !(libraryLine.include?($abc_cacheProductSearchPath))
                libraryLine = libraryLine + ' ' + $abc_cacheProductSearchPath
                content = content.sub(/LIBRARY_SEARCH_PATHS.*/, libraryLine)
                File.write(file, content)
            end
        end
    end
end

def getProductNameForTarget(target)
    if target.product_type == 'com.apple.product-type.bundle'
        buildSettings = target.build_settings('Release')
        productName = buildSettings['PRODUCT_NAME']
        return productName + '.bundle'
    end
    return File.basename(target.product_reference.path.to_s)
end

def removeTargets(targetsToRemove, targetMd5Dict, projectArray)
    targetsToRemove.each do | target |
        cacheProductPath = $abc_globalCachePath + '/' + target.name + '-' + targetMd5Dict[target] + '/' + getProductNameForTarget(target)
        searchProductPath = $abc_cacheProductSearchPath + '/' + getProductNameForTarget(target)
        copySafe(cacheProductPath, searchProductPath)
        if File.exist? searchProductPath
            removeTargetFromProjectArray(target, projectArray)
        else
            puts 'auto_build_cache_error ' + searchProductPath + ' not found'
        end
    end
    saveProjectArray(projectArray)
end

def checkTargetsToBuild(projectArray, targetsToBuild, targetsToRemove)
    targetParrents = {}
    projectArray.each do | project |
        project.targets.each do | target |
            target.dependencies.each do | dependency |
                unless targetParrents.include?(dependency.target)
                    targetParrents[dependency.target] = Set.new
                end
                targetParrents[dependency.target].add(target)
            end
        end
    end
    targetParrents.each_key do | key |
        next unless targetsToBuild.include?(key)
        if targetParrents[key].size == 1
            targetParrents[key].each do | parrent |
                if targetsToRemove.include?(parrent)
                    puts 'add target ' + parrent.name
                    targetsToRemove.delete_if { | targetToRemove | targetToRemove == parrent }
                    targetsToBuild.push(parrent)
                end
            end
        end
    end
end

def checkCache(projectArray)
    targetsToBuild = []
    targetsToRemove = []
    targetProjectDict = {}
    targetMd5Dict = {}
    projectArray.each do | project |
        project.targets.each do | target |
            unless canCacheTarget(target)
                puts 'skip target ' + target.name
                next
            end
            puts 'check cache ' + target.name
            targetMd5Content, targetMd5 = getMd5ForTarget(target)
            cacheProductPath = $abc_globalCachePath + '/' + target.name + '-' + targetMd5 + '/' + getProductNameForTarget(target)
            targetProjectDict[target] = project
            targetMd5Dict[target] = targetMd5
            if File.exist? cacheProductPath
                puts 'hit cache ' + target.name + ' md5 ' + targetMd5
                hitCacheProductPath(cacheProductPath)
                targetsToRemove.push(target)
            else
                puts 'miss cache ' + target.name + ' md5 ' + targetMd5
                targetsToBuild.push(target)
            end
        end
    end

    checkTargetsToBuild(projectArray, targetsToBuild, targetsToRemove)

    removeTargets(targetsToRemove, targetMd5Dict, projectArray)

    targetMd5DictToBuild = {}
    targetsToBuild.each do | target |
        targetMd5DictToBuild[target.name] = targetMd5Dict[target]
    end

    output = {}
    output['md5'] = targetMd5DictToBuild
    output['path'] = $abc_globalCachePath

    File.write('auto_build_cache_temp.txt', JSON.generate(output))

end

def addCopyProductsScript
    script = """
require 'json'
require 'fileutils'

def copySafe(src, dst)
    puts src
    return unless File.exist? src
    FileUtils.remove_entry dst if File.exist? dst
    FileUtils.mkdir_p(File.dirname(dst)) unless File.exist? File.dirname(dst)
    if File.file? src
        # copy content, dst is not a symlink
        FileUtils.cp(src, dst)
    else
        fileArray = Dir.glob(src + '/**/*')
        fileArray.delete_if { | file | !File.file? file }
        fileArray.each do | file |
            copySafe(file, file.gsub(src, dst))
        end
    end
end

def cacheProductsFromBuildDir(buildDir)
    puts 'buildDir = ' + buildDir
    puts 'Dir.pwd = ' + Dir.pwd
    
    return unless File.exist? 'auto_build_cache_temp.txt'
    content = File.read('auto_build_cache_temp.txt')
    output = JSON.parse(content)
    globalCachePath = output['path']
    targetMd5DictToBuild = output['md5']

    return unless (globalCachePath and globalCachePath.class == String)
    return unless (targetMd5DictToBuild and targetMd5DictToBuild.class == Hash)

    puts 'globalCachePath = ' + globalCachePath

    return unless File.exist? buildDir
    bundleArray = Dir.glob(buildDir + '/**/*.bundle')
    bundleArray.delete_if { | file | file.include? '.app/' }

    bundleArray.each do | file |
        basename = File.basename(file)
        name = basename.split('.')[0]
        targetName = name + '-' + name
        if targetMd5DictToBuild.include? targetName
            puts basename
            cacheProductPath = globalCachePath + '/' + targetName + '-' + targetMd5DictToBuild[targetName] + '/' + basename
            puts cacheProductPath
            begin
                copySafe(file, cacheProductPath)
            rescue => error
                puts 'copy error'
                puts error.message
                FileUtils.remove_entry cacheProductPath if  !File.exist? cacheProductPath
            end
            puts 'copy fail' if !File.exist? cacheProductPath
        end
    end

    libraryArray = Dir.glob(buildDir + '/**/*.a')
    libraryArray.each do | file |
        basename = File.basename(file)
        matchResult = basename.match(/^lib(.+)\.a$/)
        next unless matchResult
        targetName = matchResult[1]
        if targetMd5DictToBuild.include? targetName
            puts basename
            cacheProductPath = globalCachePath + '/' + targetName + '-' + targetMd5DictToBuild[targetName] + '/' + basename
            puts cacheProductPath
            begin
                copySafe(file, cacheProductPath)
            rescue => error
                puts 'copy error'
                puts error.message
                FileUtils.remove_entry cacheProductPath if  !File.exist? cacheProductPath
            end
            puts 'copy fail' if !File.exist? cacheProductPath
        end
    end
    
end

cacheProductsFromBuildDir(ARGV[0])
"""
    File.write('auto_build_cache_copy_product.rb', script)
    fileArray = Dir.glob('./Pods/Target Support Files/**/Pods-*-resources.sh')
    fileArray.each do | file |
        content = File.read(file)
        addition = 'ruby auto_build_cache_copy_product.rb '
        if content.include? '$PODS_CONFIGURATION_BUILD_DIR'
            addition = addition + '$PODS_CONFIGURATION_BUILD_DIR'
        elsif content.include? '${PODS_CONFIGURATION_BUILD_DIR}'
            addition = addition + '${PODS_CONFIGURATION_BUILD_DIR}'
        else
            next
        end
        addition = addition + ' >> auto_build_cache_copy_product_log.txt'
        next if content.include? addition
        content = content + "\n" + addition
        File.write(file, content)
    end

end

def hitCacheProductPath(cacheProductPath)
    # update modification time
    FileUtils.touch(File.dirname(cacheProductPath))
end

def removeOldCache
    dirArray = Dir.glob($abc_globalCachePath + "/*")
    dirTimeDict = {}
    dirArray.each do | dir |
        dirTimeDict[dir] = File.mtime(dir)
    end
    sortDirTimeArray = dirTimeDict.sort_by { | dir, mtime | mtime.to_f }
    puts 'auto_build_cache count ' + sortDirTimeArray.size.to_s
    if sortDirTimeArray.size > $abc_maxCacheCount
        puts 'remove old cache'
        dirTimeArrayToRemove = sortDirTimeArray.slice(0..(sortDirTimeArray.size-$abc_maxCacheCount-1))
        dirTimeArrayToRemove.each do | dirTime |
            puts dirTime[1].to_s + ' ' + dirTime[0]
            FileUtils.remove_entry dirTime[0]
        end
    end
end

def handleArgumentHash(argumentHash)
    argumentHash.each_key do | key |
        argument = argumentHash[key]
        if key == 'workspacePath'
            $abc_workspacePath = argument
        elsif key == 'globalCachePath'
            $abc_globalCachePath = argument
        elsif key == 'cacheProductSearchPath'
            $abc_cacheProductSearchPath = argument
        elsif key == 'maxCacheCount'
            $abc_maxCacheCount = argument.to_i
        end
    end
end

def replaceProjectArray(projectArray, project)
    projectArray.each_index do | index |
        if projectArray[index].path == project.path
            projectArray[index] = project
            break
        end
    end
end

def autoBuildCache(installer, argumentHash)
    puts 'auto_build_cache begin'

    if installer == nil or installer.pods_project == nil
        puts 'auto_build_cache_error installer invalid'
        return
    end

    startTime = Time.now

    installer.pods_project.save

    handleArgumentHash(argumentHash)

    unless File::exist?($abc_workspacePath)
        if $abc_workspacePath.size > 0
            puts 'auto_build_cache_error ' + $abc_workspacePath + ' not found'
        end
        $abc_workspacePath = getWorkspacePath
        unless File::exist?($abc_workspacePath)
            puts 'auto_build_cache_error ' + $abc_workspacePath + ' not found'
        end
    end
    projectArray = getProjectArray getProjectPathArray $abc_workspacePath

    # use installer's projects
    if installer.pods_project
        replaceProjectArray(projectArray, installer.pods_project)
    else
        puts 'auto_build_cache_error installer.pods_project nil'
    end
        
    $abc_filePathDict = getFilePathDict(projectArray)
    
    addLibrarySearchPath

    addCopyProductsScript

    checkCache(projectArray)
    
    removeOldCache

    puts 'auto_build_cache total time ' + (Time.now - startTime).to_s
    puts 'auto_build_cache end'
 end
 