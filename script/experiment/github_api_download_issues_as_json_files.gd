extends Node

@export_multiline var github_urls: String = "https://github.com/EloiStree/HelloSharpForUnity3D,"
@export_multiline var github_urls_strip: String = ""
@export var github_token: String = ""
@export var destination_folder_export: String = ""

var all_issues: Array = []           # Accumulates every issue from all pages
var current_http: HTTPRequest = null
var next_url: String = ""            # Next page URL from Link header

var working_on_url: String = ""      # Current URL being processed (for error messages)
var working_on_url_owner: String = ""       # Owner for next page (same as current)
var working_on_url_repo: String = ""        # Repo for next page (same as current)
var waiting_for_response_state: bool = false



func _ready():
	fetch_by_project_issues()

func fetch_by_project_issues() -> void:
	var lines :Array[String] = []
	lines.assign(github_urls.split("\n"))
	for i in range(lines.size()):
		lines[i] = lines[i].strip_edges().replace(".wiki.git", "").replace(".git", "").replace("git clone ", "")
	github_urls_strip = "\n".join(lines)
	
	for i in range(lines.size()-1, -1, -1):
		if lines[i].strip_edges() == "":
			lines.remove_at(i)

	for l in github_urls_strip.split("\n"):
		if l.strip_edges() != "":
			var g = l.strip_edges()
			print("Fetching issues for: %s" % g)
			waiting_for_response_state = true
			fetch_github_issues(g)
			while waiting_for_response_state:
				await get_tree().create_timer(0.2).timeout
			
			print("Done fetching issues for: %s" % g)
			await get_tree().create_timer(1.0).timeout  # Small delay between projects



func fetch_github_issues(github_url:String) -> void:
	var array = parse_github_url(github_url)
	var owner = array[0]
	var repo = array[1]
	if owner == "" or repo == "":
		push_error("Invalid GitHub URL")
		waiting_for_response_state = false
		return

	# Start with page 1, 40 items per page
	var api_url = "https://api.github.com/repos/%s/%s/issues?state=all&per_page=40" % [owner, repo]
	working_on_url = github_url
	working_on_url_owner = owner
	working_on_url_repo = repo
	start_request(api_url)

func start_request(url: String) -> void:
	if current_http:
		current_http.queue_free()

	current_http = HTTPRequest.new()
	add_child(current_http)
	current_http.connect("request_completed", Callable(self, "_on_request_completed"))
	
	var headers = [
		"Authorization: token %s" % github_token,
		"Accept: application/vnd.github+json",
		"X-GitHub-Api-Version: 2022-11-28"  # Recommended
	]
	
	var err = current_http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		push_error("Failed to start HTTP request for URL: %s" % url)
		waiting_for_response_state = false

func _on_request_completed(result: int, response_code: int, headers: Array, body: PackedByteArray) -> void:

	if response_code != 200:
		push_error("Failed to fetch issues: %d" % response_code)
		cleanup()
		waiting_for_response_state = false
		return
	var body_text = body.get_string_from_utf8()
	var json = JSON.new()
	var parse_error = json.parse(body_text)
	if parse_error != OK:
		push_error("Failed to parse JSON: %s" % json.get_error_message())
		cleanup()
		waiting_for_response_state = false
		return

	var page_issues = json.data
	if not page_issues is Array:
		push_error("Unexpected response format (not an array)")
		cleanup()
		waiting_for_response_state = false
		return

	# Append this page's issues
	all_issues.append_array(page_issues)
	print("Fetched %d issues from this page. Total so far: %d" % [page_issues.size(), all_issues.size()])

	# Check for next page in Link header
	next_url = extract_next_url_from_headers(headers)
	if next_url != "":
		# There are more pages → fetch next one
		start_request(next_url)
	else:
		# No more pages → save everything
		save_issues_to_file()
		cleanup()
		download_issue_error_count = 0
		print ("Starting to download individual issues as JSON files for %s/%s..." % [working_on_url_owner, working_on_url_repo])
		for  i in range(1,2000):
			await get_tree().create_timer(0.2).timeout 
			var file_path = get_issue_absolute_path(working_on_url_owner, working_on_url_repo, i)
			had_error = -1
			print ("Downloading issue #%d..." % i)
			print ("File path for issue #%d: %s" % [i, file_path])
			await download_issues_as_json_file(working_on_url_owner, working_on_url_repo, i , file_path)
			if had_error == 1:
				print("Error downloading issue #%d, skipping." % i)
			elif had_error == 0:
				print("Issue #%d downloaded successfully." % i)
			if had_error>=1:
				download_issue_error_count += 1
				if download_issue_error_count >= max_issue_eror_count:
					print ("Reached maximum error count for issue downloads. Stopping further attempts.\n\n\n")
					break
			parse_json_file_to_body_md(file_path)


		waiting_for_response_state = false


@export var max_issue_eror_count: int = 10
@export var download_issue_error_count: int = 0
@export var had_error =-1


func parse_json_file_to_body_md(absolute_file_path: String) -> void:
	print ("Parsing JSON file to extract body for markdown: %s" % absolute_file_path)
	if absolute_file_path.length() > 5:
		print ("File path looks valid, proceeding with parsing.")
	else:
		push_error("File path is too short, likely invalid: %s" % absolute_file_path)
		return

	var md_file_path = absolute_file_path.substr(0, absolute_file_path.length() - 5) + ".md"
	print("Markdown file path will be: %s" % md_file_path)
	
	if not FileAccess.file_exists(absolute_file_path):
		push_error("File does not exist: %s" % absolute_file_path)
		return
		
	var file = FileAccess.open(absolute_file_path, FileAccess.READ)
	if file == null:
		push_error("Failed to open file for reading: %s" % absolute_file_path)
		return 
	var content = file.get_as_text()
	file.close()
	var json = JSON.new()
	var parse_error = json.parse(content)
	if parse_error != OK:
		push_error("Failed to parse JSON from file: %s" % absolute_file_path)
		return 
	var data = json.data
	if typeof(data) != TYPE_DICTIONARY:
		push_error("Unexpected JSON format in file: %s" % absolute_file_path)
		return 
	
	var title_in_json = data.get("title", "")
	var body_in_json = data.get("body", "")
	var url_in_json = data.get("url", "")
	if title_in_json == null:
		title_in_json = ""

	# Write same file but finishing by .md and only the body content in markdown
	var md_file = FileAccess.open(md_file_path, FileAccess.WRITE)
	if md_file == null:
		push_error("Failed to open file for writing: %s" % md_file_path)
		return 
	if body_in_json!=null:
		md_file.store_string("\n".join([title_in_json, body_in_json]))
		md_file.close()

	# create file with only the title in the same folder but finishing by .title.txt
	var title_file_path = absolute_file_path.substr(0, absolute_file_path.length() - 5) + ".title.md"
	var title_file = FileAccess.open(title_file_path, FileAccess.WRITE)
	if title_file == null:
		push_error("Failed to open file for writing: %s" % title_file_path)
		return
	title_file.store_string(title_in_json)
	title_file.close()

	# create file with only the body in the same folder but finishing by .body.md
	var body_file_path = absolute_file_path.substr(0, absolute_file_path.length() - 5) + ".body.md"
	var body_file = FileAccess.open(body_file_path, FileAccess.WRITE)
	if body_file == null:
		push_error("Failed to open file for writing: %s" % body_file_path)
		return
	if body_in_json!=null:		
		body_file.store_string(body_in_json)
		body_file.close()
	
	# create window .url file with the url to the issue on github
	var url_file_path = absolute_file_path.substr(0, absolute_file_path.length() - 5) + ".url"
	var url_file = FileAccess.open(url_file_path, FileAccess.WRITE)
	if url_file == null:
		push_error("Failed to open file for writing: %s" % url_file_path)
		return
	if url_in_json!=null:
		# https://api.github.com/repos
		url_in_json = url_in_json.replace("api.github.com/repos", "github.com")
		var windo_url_content = """
[InternetShortcut]
URL= %s
""" % url_in_json
		url_file.store_string(windo_url_content)
	url_file.close()

func download_issues_as_json_file(owner: String, repo: String, issue_id: int, absolute_file_path: String) -> void:
	var api_url = "https://api.github.com/repos/%s/%s/issues/%d" % [owner, repo, issue_id]
	var http = HTTPRequest.new()
	add_child(http)
	var headers = [
		"Authorization: token %s" % github_token,
		"Accept: application/vnd.github+json",
		"X-GitHub-Api-Version: 2022-11-28"
	]
	var err = http.request(api_url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		print("ERROR:Failed to start HTTP request for issue #%d: %s" % [issue_id, err])
		http.queue_free()
		had_error = 1
		return 
	var result = await http.request_completed
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
		print("ERROR:Failed to fetch issue #%d: HTTP %d" % [issue_id, result[1]])
		http.queue_free()
		had_error = 1
		return
	http.queue_free()
	

	# create folder recursively if it doesn't exist
	var folder_path = absolute_file_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(folder_path):
		var errr = DirAccess.make_dir_recursive_absolute(folder_path)
		if errr != OK:
			push_error("Failed to create directory for issue #%d: %s" % [issue_id, errr])
			return
			
	# create the file at absolute_file_path 


	var file = FileAccess.open(absolute_file_path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to open file for writing: %s" % absolute_file_path)
		return

	var body_text = result[3].get_string_from_utf8()
	file.store_string(body_text)
	file.close()
	had_error = 0

	

	

func extract_next_url_from_headers(headers: Array) -> String:
	for header in headers:
		var h = header.to_lower()
		if h.begins_with("link:"):
			var link_value = header.substr(5).strip_edges()
			# Link header example: <url>; rel="next", <url>; rel="last"
			var parts = link_value.split(",")
			for part in parts:
				part = part.strip_edges()
				if 'rel="next"' in part:
					# Extract URL inside <>
					var start = part.find("<")
					var end = part.find(">")
					if start != -1 and end != -1:
						return part.substr(start + 1, end - start - 1)
	return ""

func save_issues_to_file() -> void:

	# owner/repository/issues.json
	var export_path = destination_folder_export.strip_edges()
	if export_path == "":
		export_path = "user://issues/" 
	var destination_folder = export_path.path_join("%s/%s/issues.json" % [working_on_url_owner, working_on_url_repo])
	if all_issues.size() <= 0:
		print("Has access but... No issues found for %s/%s, but creating empty file." % [working_on_url_owner, working_on_url_repo])
		waiting_for_response_state = false
		return

	# create folder if it doesn't exist
	var folder_path = export_path.path_join("%s/%s" % [working_on_url_owner, working_on_url_repo])
	# protect / \\ for window
	folder_path = folder_path.replace("\\", "/")
	
	if not DirAccess.dir_exists_absolute(folder_path):
		var err = DirAccess.make_dir_recursive_absolute(folder_path)
		if err != OK:
			push_error("Failed to create directory: %s" % folder_path)
			waiting_for_response_state = false
			return
	var file = FileAccess.open(destination_folder, FileAccess.WRITE)
	if file == null:
		push_error("Failed to open file for writing: %s" % destination_folder)
		waiting_for_response_state = false
		return
	
	var json_string = JSON.stringify(all_issues, "\t")
	file.store_string(json_string)
	file.close()

	print ("Issue user: %s/%s" % [working_on_url_owner, working_on_url_repo])
	print("All issues saved successfully! Total issues: %d" % all_issues.size())
	print("Saved to: %s" % destination_folder)
	print("Full OS path: %s" % ProjectSettings.globalize_path(destination_folder))


	# create a folder issues near issues.json 
	var issues_folder = export_path.path_join("%s/%s/issues" % [working_on_url_owner, working_on_url_repo])
	if not DirAccess.dir_exists_absolute(issues_folder):
		var err = DirAccess.make_dir_recursive_absolute(issues_folder)
		if err != OK:
			push_error("Failed to create issues directory: %s" % issues_folder)
			return

func get_issues_absolute_path(working_on_url_owner, working_on_url_repo) -> String:
	var export_path = destination_folder_export.strip_edges()
	if export_path == "":
		export_path = "user://issues/" 
	return export_path.path_join("%s/%s/issues.json" % [working_on_url_owner, working_on_url_repo])
	
func get_issue_absolute_path(working_on_url_owner, working_on_url_repo, issue_id) -> String:
	var export_path = destination_folder_export.strip_edges()
	if export_path == "":
		export_path = "user://issues/" 
	return export_path.path_join("%s/%s/issues/%d.json" % [working_on_url_owner, working_on_url_repo, issue_id])
	

func cleanup() -> void:
	if current_http:
		current_http.queue_free()
		current_http = null
	all_issues.clear()  # Optional: clear if you don't need to keep in memory

# Your existing parser
func parse_github_url(url: String) -> Array[String]:
	var clean_url = url.strip_edges().replace(".git", "")
	var parts = clean_url.split("/")
	if parts.size() < 2:
		return ["", ""]
	return [parts[parts.size() - 2], parts[parts.size() - 1]]
