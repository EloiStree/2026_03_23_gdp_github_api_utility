extends Node


@export var fetch_at_ready : bool = false
@export var token = ""

@onready var http_repos: HTTPRequest = HTTPRequest.new()
@onready var http_contrib: HTTPRequest = HTTPRequest.new()

@export var user_repos: Array[Dictionary] = []
@export var contributed_repos: Array[Dictionary] = []

@export_multiline() var exported:String 
# Pagination for user repos
var page: int = 1
var per_page: int = 50
var max_items: int = 2000
var total_fetched: int = 0

func _ready() -> void:
	if fetch_at_ready:
		add_child(http_repos)
		add_child(http_contrib)		
		http_repos.request_completed.connect(_on_user_repos_request_completed)
		http_contrib.request_completed.connect(_on_contrib_done)
		fetch_all()
		
	var all_for_clipboard : String = ""
	for t in user_repos:
		# t is { "name": "EloiStree/2019_02_16_TrajectoryRobot", "private": false }
		all_for_clipboard += "git clone https://github.com/" + t["name"] + ".git\n"
		
	print(all_for_clipboard)
	DisplayServer.clipboard_set(all_for_clipboard)
	exported = all_for_clipboard


# ========================
# 🚀 ENTRY POINT
# ========================
func fetch_all() -> void:
	get_user_repos()
	get_contributed_repos()


# ========================
# 📦 USER REPOSITORIES (REST API + Pagination)
# ========================
func get_user_repos() -> void:
	page = 1
	total_fetched = 0
	user_repos.clear()
	fetch_page()


func fetch_page() -> void:
	if total_fetched >= max_items:
		print("Reached maximum item limit.")
		return
		
	var url = "https://api.github.com/user/repos?page=%d&per_page=%d&affiliation=owner,collaborator,organization_member" % [page, per_page]
	
	var headers = [
		"Authorization: token %s" % token,
		"Accept: application/vnd.github+json",
		"User-Agent: Godot-GitHub-Fetcher"  # Good practice
	]
	
	var error = http_repos.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		print("HTTPRequest error: ", error)


func _on_user_repos_request_completed(
	result: int, 
	response_code: int, 
	headers: PackedStringArray, 
	body: PackedByteArray
) -> void:
	
	if response_code != 200:
		print("Failed to fetch user repos. Code: ", response_code)
		print("Body: ", body.get_string_from_utf8())
		return
	
	var json_string = body.get_string_from_utf8()
	var data = JSON.parse_string(json_string)
	
	if typeof(data) != TYPE_ARRAY:
		print("Unexpected response format.")
		return
	
	if data.size() == 0:
		print("No more repositories.")
		print_user_repos()
		return
	
	# Process current page
	for repo in data:
		user_repos.append({
			"name": repo.get("full_name", ""),
			"private": repo.get("private", false)
		})
	
	total_fetched += data.size()
	print("Fetched page %d (%d repos, total: %d)" % [page, data.size(), total_fetched])
	
	# Check if we should continue
	if total_fetched >= max_items or data.size() < per_page:
		print("Finished fetching user repositories.")
		print_user_repos()
		return
	
	# Fetch next page
	page += 1
	fetch_page()


# ========================
# 🧬 CONTRIBUTED REPOSITORIES (GraphQL)
# ========================
func get_contributed_repos() -> void:
	var url = "https://api.github.com/graphql"
	
	var query = {
		"query": """
        {
          viewer {
            repositoriesContributedTo(first: 100, contributionTypes: [COMMIT, PULL_REQUEST, ISSUE, PULL_REQUEST_REVIEW, REPOSITORY]) {
              nodes {
                nameWithOwner
                isPrivate
              }
            }
          }
        }
		"""
	}
	
	var headers = [
		"Authorization: Bearer %s" % token,
		"Content-Type: application/json",
        "User-Agent: Godot-GitHub-Fetcher"
	]
	
	var error = http_contrib.request(
		url, 
		headers, 
		HTTPClient.METHOD_POST, 
		JSON.stringify(query)
	)
	
	if error != OK:
		print("Contrib HTTPRequest error: ", error)


func _on_contrib_done(
	result: int, 
	response_code: int, 
	headers: PackedStringArray, 
	body: PackedByteArray
) -> void:
	
	if response_code != 200:
		print("Failed to fetch contributed repos. Code: ", response_code)
		print("Body: ", body.get_string_from_utf8())
		return
	
	var json = JSON.parse_string(body.get_string_from_utf8())
	
	if not json or not json.has("data"):
		print("Invalid GraphQL response")
		return
	
	contributed_repos.clear()
	
	var nodes = json["data"]["viewer"]["repositoriesContributedTo"]["nodes"]
	
	for repo in nodes:
		contributed_repos.append({
			"name": repo.get("nameWithOwner", ""),
			"private": repo.get("isPrivate", false)
		})
	
	print_contributed_repos()


# ========================
# 🖨️ OUTPUT
# ========================
func print_user_repos() -> void:
	print("\n=== YOUR REPOSITORIES (%d) ===" % user_repos.size())
	for repo in user_repos:
		var visibility = "Private" if repo["private"] else "Public"
		print("• %s (%s)" % [repo["name"], visibility])


func print_contributed_repos() -> void:
	print("\n=== CONTRIBUTED REPOSITORIES (%d) ===" % contributed_repos.size())
	for repo in contributed_repos:
		var visibility = "Private" if repo["private"] else "Public"
		print("• %s (%s)" % [repo["name"], visibility])
