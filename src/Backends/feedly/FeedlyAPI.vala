public class FeedlyAPI : Object {

	private FeedlyConnection m_connection;
	private string m_token;
	private string m_refresh_token;
	private string m_userID;
	private Gee.HashMap<string,int> markers;

	public FeedlyAPI() {
		m_connection = new FeedlyConnection();
	}
	
	public int login()
	{
		if(feedreader_settings.get_string("feedly-refresh-token") == "")
		{
			m_connection.getToken();
		}
		getUserID();
		return LOGIN_SUCCESS;
	}
	
	private void getUserID()
	{
		string response = m_connection.send_get_request_to_feedly ("/v3/profile/");
		var parser = new Json.Parser ();
		parser.load_from_data (response, -1);
		var root = parser.get_root().get_object();
		m_userID = root.get_string_member("id");
		print(m_userID + "\n");
	}


	public async void getCategories() throws Error {
		SourceFunc callback = getCategories.callback;
		ThreadFunc<void*> run = () => {
			string response = m_connection.send_get_request_to_feedly ("/v3/categories/");

			var parser = new Json.Parser();
			parser.load_from_data (response, -1);
			Json.Array array = parser.get_root ().get_array ();
			
			for (int i = 0; i < array.get_length (); i++) {
				Json.Object object = array.get_object_element(i);
				
				string categorieID = object.get_string_member("id");
				int unreadCount = get_count_of_unread_articles(categorieID);
				string title = object.get_string_member("label");
				
				//stdout.printf("%s %i\n", title, unreadCount);
				dataBase.write_categorie(categorieID, title, unreadCount, i+1, -99, 1);
				//getArticles(categorieID);
			}
			
			Idle.add((owned) callback);
			return null;
		};
		new GLib.Thread<void*>("getCategories", run);
		yield;
	}


	public async void getFeeds() throws Error {
		SourceFunc callback = getFeeds.callback;
		ThreadFunc<void*> run = () => {
			string response = m_connection.send_get_request_to_feedly("/v3/subscriptions/");
			//stdout.printf("%s\n", response);
			
			var parser = new Json.Parser();
			parser.load_from_data(response, -1);
			Json.Array array = parser.get_root().get_array ();

			for (int i = 0; i < array.get_length(); i++) {
				Json.Object object = array.get_object_element(i);
				
				string feedID = object.get_string_member("id");
				string title = object.get_string_member("title");
				
				string icon_url = "";
				if(object.has_member("iconUrl"))
				{
					icon_url = object.get_string_member("iconUrl");
					downloadIcon(feedID, icon_url);
				}
				else if(object.has_member("visualUrl"))
				{
					icon_url = object.get_string_member("visualUrl");
					downloadIcon(feedID, icon_url);
				}
				
				string url = object.has_member("website") ? object.get_string_member("website") : "";
				var categories = object.get_array_member("categories");
				var category = categories.get_object_element(0);
				string categorieID = category.get_string_member("id");
				int unreadCount = get_count_of_unread_articles(feedID);
	 			
				dataBase.write_feed(feedID,
									title,
									url,
									(icon_url == "") ? false : true,
									unreadCount,
									categorieID);
			}
			
			Idle.add((owned) callback);
			return null;
		};
		new GLib.Thread<void*>("getFeeds", run);
		yield;
	}



	public async void getArticles() throws Error {
		SourceFunc callback = getArticles.callback;
		ThreadFunc<void*> run = () => {
			int maxArticles = feedreader_settings.get_int("max-articles");
			string allArticles = "user/" + m_userID + "/category/global.all";
			string entry_id_response = m_connection.send_get_request_to_feedly("/v3/streams/ids?streamId=%s&unreadOnly=false&count=%i&ranked=newest".printf(allArticles, maxArticles));
			string response = m_connection.send_post_string_request_to_feedly("/v3/entries/.mget", entry_id_response,"application/json");
			
			var parser = new Json.Parser();
			parser.load_from_data(response, -1);

			var array = parser.get_root().get_array();
			
			GLib.List<article> articles = new GLib.List<article>();

			for(int i = 0; i < array.get_length(); i++) {
				Json.Object object = array.get_object_element(i);
				string id = object.get_string_member("id");
				string title = object.has_member("title") ? object.get_string_member("title") : "No title specified";
				string author = object.has_member("author") ? object.get_string_member("author") : "None";
				string summaryContent = object.has_member("summary") ? object.get_object_member("summary").get_string_member("content") : "";
				string Content = object.has_member("content") ? object.get_object_member("content").get_string_member("content") : summaryContent;
				bool unread = object.get_boolean_member("unread");
				string url = object.has_member("alternate") ? object.get_array_member("alternate").get_object_element(0).get_string_member("href") : "";
				string feedID = object.get_object_member("origin").get_string_member("streamId");
				
				articles.append(new article(id, title, url, feedID, (unread) ? STATUS_UNREAD : STATUS_READ, STATUS_UNMARKED, Content, summaryContent, author));
			}
			articles.reverse();
			
			// first write all new articles
			foreach(article item in articles)
			{
				dataBase.write_article(	item.m_articleID,
										item.m_feedID,
										item.m_title,
										item.m_author,
										item.m_url,
										item.m_unread,
										item.m_marked,
										DB_INSERT_OR_IGNORE,
										item.m_html,
										item.m_preview);
			}
			
			
			// then only update marked and unread for all others
			foreach(article item in articles)
			{
				dataBase.write_article(	item.m_articleID,
										item.m_feedID,
										item.m_title,
										item.m_author,
										item.m_url,
										item.m_unread,
										item.m_marked,
										DB_INSERT_OR_REPLACE,
										item.m_html,
										item.m_preview);
			}
			
			Idle.add((owned) callback);
			return null;
		};
		new GLib.Thread<void*>("getArticles", run);
		yield;
	}


	private void downloadIcon(string feed_id, string icon_url)
	{
		string icon_path = GLib.Environment.get_home_dir() + "/.local/share/feedreader/data/feed_icons/";
		var path = GLib.File.new_for_path(icon_path);
		try{path.make_directory_with_parents();}catch(GLib.Error e){}
		string local_filename = icon_path + feed_id.replace("/", "_").replace(".", "_") + ".ico";
		
		if(!FileUtils.test (local_filename, GLib.FileTest.EXISTS))
		{
			Soup.Message message_dlIcon;
			message_dlIcon = new Soup.Message ("GET", icon_url);
			var session = new Soup.Session ();
			var status = session.send_message(message_dlIcon);
			if (status == 200)
				try{FileUtils.set_contents(local_filename, (string)message_dlIcon.response_body.flatten().data, (long)message_dlIcon.response_body.length);}
				catch(GLib.FileError e){}
		}
	}

	/** Returns the number of unread articles for an ID (may be a feed, subscription, category or tag */
	public unowned int get_count_of_unread_articles (string id) throws Error {
		string response = m_connection.send_get_request_to_feedly ("/v3/markers/counts");

		var parser = new Json.Parser ();
		parser.load_from_data (response, -1);

		var object = parser.get_root ().get_object ();

		var unreadcounts = object.get_array_member ("unreadcounts");

		int unread_count = -1;

		for (int i = 0; i < unreadcounts.get_length (); i++) {
			var unread = unreadcounts.get_object_element (i);
			
			string unread_id = unread.get_string_member ("id");
			
			if (id == unread_id) {
				unread_count = (int)unread.get_int_member ("count");
				break;
			}
		}
		
		if(unread_count == -1) {
			error("Unkown id: " + id);
		}
		
		return unread_count;
	}
	
	
	public async void mark_as_read(string id, string type, int read) {
		SourceFunc callback = mark_as_read.callback;
		ThreadFunc<void*> run = () => {
			Json.Object object = new Json.Object();
		
			if(read == STATUS_READ)
				object.set_string_member ("action", "markAsRead");
			else if(read == STATUS_UNREAD)
				object.set_string_member ("action", "undoMarkAsRead");
			object.set_string_member ("type", type);
		
			Json.Array ids = new Json.Array();
			ids.add_string_element (id);
		
			string* type_id_identificator = null;
		
			if(type == "entries") {
				type_id_identificator = "entryIds";
			} else if(type == "feeds") {
				type_id_identificator = "feedIds";
			} else if(type == "categories") {
				type_id_identificator = "categoryIds";
			} else {
				error ("Unknown type: " + type + " don't know what to do with this.");
			}
		
			object.set_array_member (type_id_identificator, ids);
		
			var root = new Json.Node(Json.NodeType.OBJECT);
			root.set_object (object);
		
			m_connection.send_post_request_to_feedly ("/v3/markers", root);
			Idle.add((owned) callback);
			return null;
		};
		new GLib.Thread<void*>("mark_as_read", run);
		yield;
	}
}
