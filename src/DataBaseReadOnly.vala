//	This file is part of FeedReader.
//
//	FeedReader is free software: you can redistribute it and/or modify
//	it under the terms of the GNU General Public License as published by
//	the Free Software Foundation, either version 3 of the License, or
//	(at your option) any later version.
//
//	FeedReader is distributed in the hope that it will be useful,
//	but WITHOUT ANY WARRANTY; without even the implied warranty of
//	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//	GNU General Public License for more details.
//
//	You should have received a copy of the GNU General Public License
//	along with FeedReader.  If not, see <http://www.gnu.org/licenses/>.

public class FeedReader.DataBaseReadOnly : GLib.Object {

	protected SQLite m_db;

	public DataBaseReadOnly(string db_file = "feedreader-%01i.db".printf(Constants.DB_SCHEMA_VERSION))
	{
		Sqlite.config(Sqlite.Config.LOG, errorLogCallback);
		string db_path = GLib.Environment.get_user_data_dir() + "/feedreader/data/" + db_file;

		Logger.debug(@"Opening Database: $db_path");
		m_db = new SQLite(db_path);
	}

	private void errorLogCallback(int code, string msg)
	{
		Logger.error(@"dbErrorLog: $code: $msg");
	}

	public void init()
	{
		Logger.debug("init database");
		m_db.simple_query("PRAGMA journal_mode = WAL");
		m_db.simple_query("PRAGMA page_size = 4096");

		m_db.simple_query("""
			CREATE  TABLE  IF NOT EXISTS "main"."feeds"
			(
				"feed_id" TEXT PRIMARY KEY NOT NULL UNIQUE,
				"name" TEXT NOT NULL,
				"url" TEXT NOT NULL,
				"category_id" TEXT,
				"subscribed" INTEGER DEFAULT 1,
				"xmlURL" TEXT,
				"iconURL" TEXT
			)
		""");

		m_db.simple_query("""
			CREATE  TABLE  IF NOT EXISTS "main"."categories"
			(
				"categorieID" TEXT PRIMARY KEY NOT NULL UNIQUE,
				"title" TEXT NOT NULL,
				"orderID" INTEGER,
				"exists" INTEGER,
				"Parent" TEXT,
				"Level" INTEGER
			)
		""");

		m_db.simple_query("""
			CREATE  TABLE  IF NOT EXISTS "main"."articles"
			(
				"articleID" TEXT PRIMARY KEY NOT NULL UNIQUE,
				"feedID" TEXT NOT NULL,
				"title" TEXT NOT NULL,
				"author" TEXT,
				"url" TEXT NOT NULL,
				"html" TEXT NOT NULL,
				"preview" TEXT NOT NULL,
				"unread" INTEGER NOT NULL,
				"marked" INTEGER NOT NULL,
				"tags" TEXT,
				"date" INTEGER NOT NULL,
				"guidHash" TEXT,
				"lastModified" INTEGER,
				"media" TEXT,
				"contentFetched" INTEGER NOT NULL
			)
		""");

		m_db.simple_query("""
			CREATE  TABLE  IF NOT EXISTS "main"."tags"
			(
				"tagID" TEXT PRIMARY KEY NOT NULL UNIQUE,
				"title" TEXT NOT NULL,
				"exists" INTEGER,
				"color" INTEGER
			)
		""");

		m_db.simple_query("""
			CREATE  TABLE  IF NOT EXISTS "main"."CachedActions"
			(
				"action" INTEGER NOT NULL,
				"id" TEXT NOT NULL,
				"argument" INTEGER
			)
		""");

		m_db.simple_query("""
			CREATE INDEX IF NOT EXISTS "index_articles"
			ON "articles" ("feedID" DESC, "unread" ASC, "marked" ASC)
		""");
		m_db.simple_query("""
			CREATE VIRTUAL TABLE IF NOT EXISTS fts_table
			USING fts4 (content='articles', articleID, preview, title, author)
		""");
	}

	public bool uninitialized()
	{
		string query = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='articles'";
		var rows = m_db.execute(query);
		assert(rows.size == 1 && rows[0].size == 1);
		return (int)rows[0][0] == 0;
	}

	public bool isEmpty()
	{
		return isTableEmpty("articles")
			&& isTableEmpty("categories")
			&& isTableEmpty("feeds")
			&& isTableEmpty("tags");
	}

	public bool isTableEmpty(string table)
	{
		var query = @"SELECT COUNT(*) FROM $table";
		var rows = m_db.execute(query);
		assert(rows.size == 1 && rows[0].size == 1);
		return (int)rows[0][0] == 0;
	}

	public uint get_unread_total()
	{
		var query = "SELECT COUNT(*) FROM articles WHERE unread = ?";
		var rows = m_db.execute(query, { ArticleStatus.UNREAD.to_string() });
		assert(rows.size == 1 && rows[0].size == 1);
		return (int)rows[0][0];
	}

	public uint get_marked_total()
	{
		var query = "SELECT COUNT(*) FROM articles WHERE marked = ?";
		var rows = m_db.execute(query, { ArticleStatus.MARKED.to_string() });
		assert(rows.size == 1 && rows[0].size == 1);
		return (int)rows[0][0];
	}

	public uint get_unread_uncategorized()
	{
		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("count(*)");
		query.addEqualsCondition("unread", ArticleStatus.UNREAD.to_string());
		query.addCustomCondition(getUncategorizedFeedsQuery());
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		int unread = 0;
		while (stmt.step() == Sqlite.ROW) {
			unread = stmt.column_int(0);
		}
		stmt.reset();
		return unread;
	}

	public uint get_marked_uncategorized()
	{
		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("count(*)");
		query.addEqualsCondition("marked", ArticleStatus.MARKED.to_string());
		query.addCustomCondition(getUncategorizedFeedsQuery());
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		int marked = 0;
		while (stmt.step() == Sqlite.ROW) {
			marked = stmt.column_int(0);
		}
		stmt.reset();
		return marked;
	}

	public int getTagColor()
	{
		var query = new QueryBuilder(QueryType.SELECT, "tags");
		query.selectField("count(*)");
		query.addCustomCondition("instr(tagID, \"global.\") = 0");
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		int tagCount = 0;
		while (stmt.step () == Sqlite.ROW) {
			tagCount = stmt.column_int(0);
		}
		stmt.reset ();

		return (tagCount % Constants.COLORS.length);
	}

	public bool tag_still_used(Tag tag)
	{
		var query = "SELECT 1 FROM main.articles WHERE instr(tagID, ?) > 0 LIMIT 1";
		var rows = m_db.execute(query, { tag.getTagID() });
		return rows.size > 0;
	}

	public string? getTagName(string tag_id)
	{
		var query = "SELECT title FROM tags WHERE tagID = ?";
		var rows = m_db.execute(query, { tag_id });
		assert(rows.size == 0 || (rows.size == 1 && rows[0].size == 1));
		if(rows.size == 1)
			return (string)rows[0][0];
		return _("Unknown tag");
	}

	public int getLastModified()
	{
		var query = "SELECT MAX(lastModified) FROM articles";
		var rows = m_db.execute(query);
		assert(rows.size == 0 || (rows.size == 1 && rows[0].size == 1));
		if(rows.size == 1 && rows[0][0] != null)
			return (int)rows[0][0];
		else
			return 0;
	}


	public string getCategoryName(string catID)
	{
		if(catID == CategoryID.TAGS.to_string())
			return "Tags";

		var query = new QueryBuilder(QueryType.SELECT, "categories");
		query.selectField("title");
		query.addEqualsCondition("categorieID", catID, true, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		string result = "";

		while (stmt.step () == Sqlite.ROW) {
			result = stmt.column_text(0);
		}

		if(result == "")
			result = _("Uncategorized");

		return result;
	}


	public string? getCategoryID(string catname)
	{
		var query = new QueryBuilder(QueryType.SELECT, "categories");
		query.selectField("categorieID");
		query.addEqualsCondition("title", catname, true, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		string? result = null;

		while (stmt.step () == Sqlite.ROW) {
			result = stmt.column_text(0);
		}

		return result;
	}


	public bool preview_empty(string articleID)
	{
		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("count(*)");
		query.addEqualsCondition("articleID", articleID, true, true);
		query.addEqualsCondition("preview", "", false, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		int result = 1;

		while (stmt.step () == Sqlite.ROW) {
			result = stmt.column_int(0);
		}

		if(result == 1)
			return false;
		if(result == 0)
			return true;

		return true;
	}

	public Gee.List<Article> read_article_between(
		string feedID,
		FeedListType selectedType,
		ArticleListState state,
		string searchTerm,
		string id1,
		GLib.DateTime date1,
		string id2,
		GLib.DateTime date2)
	{
		var query = articleQuery(feedID, selectedType, state, searchTerm);
		var sorting = (ArticleListSort)Settings.general().get_enum("articlelist-sort-by");

		if(sorting == ArticleListSort.RECEIVED)
			query.addCustomCondition(@"date BETWEEN (SELECT rowid FROM articles WHERE articleID = \"$id1\") AND (SELECT rowid FROM articles WHERE articleID = \"$id2\")");
		else
		{
			bool bigger = (date1.to_unix() > date2.to_unix());
			var biggerDate = (bigger) ? date1.to_unix() : date2.to_unix();
			var smallerDate = (bigger) ? date2.to_unix() : date1.to_unix();
			query.addCustomCondition(@"date BETWEEN $smallerDate AND $biggerDate");
		}
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		var articles = new Gee.ArrayList<Article>();
		while (stmt.step () == Sqlite.ROW)
		{
			if(stmt.column_text(2) == id1
			|| stmt.column_text(2) == id2)
				continue;

			articles.add(new Article(
								stmt.column_text(2),																		// articleID
								stmt.column_text(3),																		// title
								stmt.column_text(5),																		// url
								stmt.column_text(1),																		// feedID
								(ArticleStatus)stmt.column_int(7),											// unread
								(ArticleStatus)stmt.column_int(8),											// marked
								null,																											// html
								stmt.column_text(6),																		// preview
								stmt.column_text(4),																		// author
								new GLib.DateTime.from_unix_local(stmt.column_int(10)),	// date
								stmt.column_int(0),																			// sortID
								StringUtils.split(stmt.column_text(9), ",", true), 			// tags
								StringUtils.split(stmt.column_text(12), ",", true),			// media
								stmt.column_text(11)																		// guid
							));
		}
		stmt.reset();
		return articles;
	}

	public Gee.HashMap<string, Article> read_article_stats(Gee.List<string> ids)
	{
		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("articleID, unread, marked");
		query.addRangeConditionString("articleID", ids);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		var articles = new Gee.HashMap<string, Article>();

		while(stmt.step() == Sqlite.ROW)
		{
			articles.set(stmt.column_text(0),
								new Article(stmt.column_text(0), null, null, null, (ArticleStatus)stmt.column_int(1),
								(ArticleStatus)stmt.column_int(2), null, null, null, new GLib.DateTime.now_local()));
		}
		stmt.reset();
		return articles;
	}

	public Article? read_article(string articleID)
	{
		Logger.debug(@"DataBaseReadOnly.read_article(): $articleID");
		Article? tmp = null;
		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("ROWID");
		query.selectField("*");
		query.addEqualsCondition("articleID", articleID, true, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while(stmt.step() == Sqlite.ROW)
		{
			string? author = (stmt.column_text(4) == "") ? null : stmt.column_text(4);
			tmp = new Article(
								articleID,
								stmt.column_text(3),
								stmt.column_text(5),
								stmt.column_text(2),
								(ArticleStatus)stmt.column_int(8),
								(ArticleStatus)stmt.column_int(9),
								stmt.column_text(6),
								stmt.column_text(7),
								author,
								new GLib.DateTime.from_unix_local(stmt.column_int(11)),
								stmt.column_int(0), // rowid (sortid)
								StringUtils.split(stmt.column_text(10), ",", true), // tags
								StringUtils.split(stmt.column_text(14), ",", true), // media
								stmt.column_text(12)  // guid
							);
		}
		stmt.reset();
		return tmp;
	}

	public int getMaxCatLevel()
	{
		int maxCatLevel = 0;

		var query = new QueryBuilder(QueryType.SELECT, "categories");
		query.selectField("max(Level)");
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());
		while (stmt.step () == Sqlite.ROW) {
			maxCatLevel = stmt.column_int(0);
		}

		if(maxCatLevel == 0)
		{
			maxCatLevel = 1;
		}

		return maxCatLevel;
	}

	public bool haveFeedsWithoutCat()
	{
		var query = new QueryBuilder(QueryType.SELECT, "feeds");
		query.selectField("count(*)");
		query.addCustomCondition(getUncategorizedQuery());
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			int count = stmt.column_int(0);

			if(count > 0)
				return true;
		}
		return false;
	}

	public bool haveCategories()
	{
		var query = new QueryBuilder(QueryType.SELECT, "categories");
		query.selectField("count(*)");
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());
		while (stmt.step () == Sqlite.ROW) {
			int count = stmt.column_int(0);

			if(count > 0)
				return true;
		}

		return false;
	}

	public bool article_exists(string articleID)
	{
		int result = 0;
		string query = "SELECT EXISTS(SELECT 1 FROM articles WHERE articleID = \"" + articleID + "\" LIMIT 1)";
		Sqlite.Statement stmt = m_db.prepare(query);

		while (stmt.step () == Sqlite.ROW) {
			result = stmt.column_int(0);
		}
		if(result == 1)
			return true;

		return false;
	}

	public bool category_exists(string catID)
	{
		int result = 0;
		string query = "SELECT EXISTS(SELECT 1 FROM categories WHERE categorieID = \"" + catID + "\" LIMIT 1)";
		Sqlite.Statement stmt = m_db.prepare(query);
		while (stmt.step () == Sqlite.ROW) {
			result = stmt.column_int(0);
		}
		if(result == 1)
			return true;

		return false;
	}


	public int getRowCountHeadlineByDate(string date)
	{
		int result = 0;

		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("count(*)");
		query.addCustomCondition("date > \"%s\"".printf(date));
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			result = stmt.column_int(0);
		}

		return result;
	}


	public int getArticleCountNewerThanID(string articleID, string feedID, FeedListType selectedType, ArticleListState state, string searchTerm, int searchRows = 0)
	{
		int result = 0;
		string orderBy = ((ArticleListSort)Settings.general().get_enum("articlelist-sort-by") == ArticleListSort.RECEIVED) ? "rowid" : "date";

		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.addEqualsCondition("articleID", articleID, true, true);

		var query2 = new QueryBuilder(QueryType.SELECT, "articles");
		query2.selectField("count(*)");


		query.selectField(orderBy);
		query.build();

		if(Settings.general().get_boolean("articlelist-oldest-first") && state == ArticleListState.UNREAD)
			query2.addCustomCondition(@"$orderBy < (%s)".printf(query.get()));
		else
			query2.addCustomCondition(@"$orderBy > (%s)".printf(query.get()));


		if(selectedType == FeedListType.FEED && feedID != FeedID.ALL.to_string())
		{
			query2.addEqualsCondition("feedID", feedID, true, true);
		}
		else if(selectedType == FeedListType.CATEGORY && feedID != CategoryID.MASTER.to_string() && feedID != CategoryID.TAGS.to_string())
		{
			query2.addRangeConditionString("feedID", getFeedIDofCategorie(feedID));
		}
		else if(feedID == CategoryID.TAGS.to_string())
		{
			query2.addCustomCondition(getAllTagsCondition());
		}
		else if(selectedType == FeedListType.TAG)
		{
			query2.addCustomCondition("instr(tags, \"%s\") > 0".printf(feedID));
		}

		if(state == ArticleListState.UNREAD)
		{
			query2.addEqualsCondition("unread", ArticleStatus.UNREAD.to_string());
		}
		else if(state == ArticleListState.MARKED)
		{
			query2.addEqualsCondition("marked", ArticleStatus.MARKED.to_string());
		}

		if(searchTerm != ""){
			if(searchTerm.has_prefix("title: "))
			{
				query2.addCustomCondition("articleID IN (SELECT articleID FROM fts_table WHERE title MATCH '%s')".printf(Utils.prepareSearchQuery(searchTerm)));
			}
			else if(searchTerm.has_prefix("author: "))
			{
				query2.addCustomCondition("articleID IN (SELECT articleID FROM fts_table WHERE author MATCH '%s')".printf(Utils.prepareSearchQuery(searchTerm)));
			}
			else if(searchTerm.has_prefix("content: "))
			{
				query2.addCustomCondition("articleID IN (SELECT articleID FROM fts_table WHERE preview MATCH '%s')".printf(Utils.prepareSearchQuery(searchTerm)));
			}
			else
			{
				query2.addCustomCondition("articleID IN (SELECT articleID FROM fts_table WHERE fts_table MATCH '%s')".printf(Utils.prepareSearchQuery(searchTerm)));
			}
		}

		bool desc = true;
		string asc = "DESC";
		if(Settings.general().get_boolean("articlelist-oldest-first") && state == ArticleListState.UNREAD)
		{
			desc = false;
			asc = "ASC";
		}

		if(searchRows != 0)
			query.addCustomCondition(@"articleID in (SELECT articleID FROM articles ORDER BY $orderBy $asc LIMIT $searchRows)");

		query2.orderBy(orderBy, desc);
		query2.build();

		Sqlite.Statement stmt = m_db.prepare(query2.get());

		while (stmt.step () == Sqlite.ROW) {
			result = stmt.column_int(0);
		}

		return result;
	}

	public Gee.List<string> getFeedIDofCategorie(string categorieID)
	{
		var feedIDs = new Gee.ArrayList<string>();

		var query = new QueryBuilder(QueryType.SELECT, "feeds");
		query.selectField("feed_id, category_id");
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step() == Sqlite.ROW) {
			string catString = stmt.column_text(1);
			string[] categories = catString.split(",");

			if(categorieID == "")
			{
				if((categories.length == 0)
				||(categories.length == 1 && categories[0].contains("global.must")))
				{
					feedIDs.add(stmt.column_text(0));
				}
			}
			else
			{
				foreach(string cat in categories)
				{
					if(cat == categorieID)
					{
						feedIDs.add(stmt.column_text(0));
					}
				}
			}
		}
		return feedIDs;
	}

	protected string getUncategorizedQuery()
	{
		string catID = FeedServer.get_default().uncategorizedID();
		return "category_id = \"%s\"".printf(catID);
	}

	protected bool showCategory(string catID, Gee.List<Feed> feeds)
	{
		if(FeedServer.get_default().hideCategoryWhenEmpty(catID)
		&& !Utils.categoryIsPopulated(catID, feeds))
		{
			return false;
		}
		return true;
	}

	protected string getUncategorizedFeedsQuery()
	{
		string sql = "feedID IN (%s)";

		var query = new QueryBuilder(QueryType.SELECT, "feeds");
		query.selectField("feed_id");
		query.addCustomCondition(getUncategorizedQuery());
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		string feedIDs = "";
		while (stmt.step () == Sqlite.ROW) {
			feedIDs += "\"" + stmt.column_text(0) + "\"" + ",";
		}

		return sql.printf(feedIDs.substring(0, feedIDs.length-1));
	}


	public string getFeedIDofArticle(string articleID)
	{
		string query = "SELECT feedID FROM \"main\".\"articles\" WHERE \"articleID\" = " + "\"" + articleID + "\"";
		Sqlite.Statement stmt = m_db.prepare(query);

		string id = "";
		while (stmt.step () == Sqlite.ROW) {
			id = stmt.column_text(0);
		}
		return id;
	}


	public string getNewestArticle()
	{
		string result = "";

		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("articleID");
		query.addEqualsCondition("rowid", "%s".printf(getMaxID("articles", "rowid")));
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			result = stmt.column_text(0);
		}
		return result;
	}

	public string getMaxID(string table, string field)
	{
		string maxID = "0";
		var query = new QueryBuilder(QueryType.SELECT, table);
		query.selectField("max(%s)".printf(field));
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW)
		{
			maxID = stmt.column_text(0);
		}

		return maxID;
	}

	public bool feed_exists(string feed_url)
	{
		var query = new QueryBuilder(QueryType.SELECT, "main.feeds");
		query.selectField("count(*)");
		query.addEqualsCondition("url", feed_url, true, true);
		query.limit(1);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			if(stmt.column_int(0) > 1)
				return true;
		}

		return false;
	}

	public Feed? read_feed(string feedID)
	{
		var query = new QueryBuilder(QueryType.SELECT, "feeds");
		query.selectField("*");
		query.addEqualsCondition("feed_id", feedID, true, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while(stmt.step () == Sqlite.ROW)
		{
			var feed = new Feed(
				feedID,
				stmt.column_text(1),
				stmt.column_text(2),
				getFeedUnread(feedID),
				StringUtils.split(stmt.column_text(3), ",", true),
				stmt.column_text(6),
				stmt.column_text(5));
			return feed;
		}

		return null;
	}


	public Gee.List<Feed> read_feeds(bool starredCount = false)
	{
		Gee.List<Feed> feeds = new Gee.ArrayList<Feed>();

		var query = new QueryBuilder(QueryType.SELECT, "feeds");
		query.selectField("*");
		if(Settings.general().get_enum("feedlist-sort-by") == FeedListSort.ALPHABETICAL)
		{
			query.orderBy("name", true);
		}
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			string feedID = stmt.column_text(0);
			string catString = stmt.column_text(3);
			string xmlURL = stmt.column_text(5);
			string iconURL = stmt.column_text(6);
			string url = stmt.column_text(2);
			string name = stmt.column_text(1);
			var categories = StringUtils.split(catString, ",", true);

			uint count = 0;
			if(starredCount)
				count = getFeedStarred(feedID);
			else
				count = getFeedUnread(feedID);

			var feed = new Feed(feedID, name, url, count, categories, iconURL, xmlURL);
			feeds.add(feed);
		}

		return feeds;
	}


	public uint getFeedUnread(string feedID)
	{
		uint count = 0;

		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("count(*)");
		query.addEqualsCondition("unread", ArticleStatus.UNREAD.to_string());
		query.addEqualsCondition("feedID", feedID, true, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			count = (uint)stmt.column_int(0);
		}
		return count;
	}

	public uint getFeedStarred(string feedID)
	{
		uint count = 0;

		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("count(*)");
		query.addEqualsCondition("marked", ArticleStatus.MARKED.to_string());
		query.addEqualsCondition("feedID", feedID, true, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			count = (uint)stmt.column_int(0);
		}
		return count;
	}


	public Gee.List<Feed> read_feeds_without_cat()
	{
		var feeds = new Gee.ArrayList<Feed>();

		var query = new QueryBuilder(QueryType.SELECT, "feeds");
		query.selectField("*");
		query.addCustomCondition(getUncategorizedQuery());
		if(Settings.general().get_enum("feedlist-sort-by") == FeedListSort.ALPHABETICAL)
		{
			query.orderBy("name", true);
		}
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			string feedID = stmt.column_text(0);
			string catString = stmt.column_text(3);
			string xmlURL = stmt.column_text(5);
			string iconURL = stmt.column_text(6);
			string url = stmt.column_text(2);
			string name = stmt.column_text(1);
			var categories = StringUtils.split(catString, ",", true);
			var feed = new Feed(feedID, name, url, getFeedUnread(feedID), categories, iconURL, xmlURL);
			feeds.add(feed);
		}

		return feeds;
	}

	public Category? read_category(string catID)
	{
		var query = new QueryBuilder(QueryType.SELECT, "categories");
		query.selectField("*");
		query.addEqualsCondition("categorieID", catID, true, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			var tmpcategory = new Category(
				catID,
				stmt.column_text(1),
				0,
				stmt.column_int(3),
				stmt.column_text(4),
				stmt.column_int(5)
			);
			return tmpcategory;
		}

		return null;
	}


	public Gee.List<Tag> read_tags()
	{
		Gee.List<Tag> tmp = new Gee.ArrayList<Tag>();
		Tag tmpTag;

		var query = new QueryBuilder(QueryType.SELECT, "tags");
		query.selectField("*");
		query.addCustomCondition("instr(tagID, \"global.\") = 0");
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			tmpTag = new Tag(stmt.column_text(0), stmt.column_text(1), stmt.column_int(3));
			tmp.add(tmpTag);
		}

		return tmp;
	}

	public Tag? read_tag(string tagID)
	{
		Tag tmpTag = null;

		var query = new QueryBuilder(QueryType.SELECT, "tags");
		query.selectField("*");
		query.addEqualsCondition("tagID", tagID, true, true);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			tmpTag = new Tag(stmt.column_text(0), stmt.column_text(1), stmt.column_int(3));
		}

		return tmpTag;
	}

	protected string getAllTagsCondition()
	{
		var tags = read_tags();
		string query = "(";
		foreach(Tag tag in tags)
		{
			query += "instr(\"tags\", \"%s\") > 0 OR ".printf(tag.getTagID());
		}

		int or = query.char_count()-4;
		return query.substring(0, or) + ")";
	}

	public int getTagCount()
	{
		int count = 0;
		var query = new QueryBuilder(QueryType.SELECT, "tags");
		query.addCustomCondition("instr(tagID, \"global.\") = 0");
		query.selectField("count(*)");
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while (stmt.step () == Sqlite.ROW) {
			count = stmt.column_int(0);
		}

		return count;
	}

	public Gee.List<Category> read_categories_level(int level, Gee.List<Feed>? feeds = null)
	{
		var categories = read_categories(feeds);
		var tmpCategories = new Gee.ArrayList<Category>();

		foreach(Category cat in categories)
		{
			if(cat.getLevel() == level)
			{
				tmpCategories.add(cat);
			}
		}

		return tmpCategories;
	}

	public Gee.List<Category> read_categories(Gee.List<Feed>? feeds = null)
	{
		Gee.List<Category> tmp = new Gee.ArrayList<Category>();

		var query = new QueryBuilder(QueryType.SELECT, "categories");
		query.selectField("*");

		if(Settings.general().get_enum("feedlist-sort-by") == FeedListSort.ALPHABETICAL)
		{
			query.orderBy("title", true);
		}
		else
		{
			query.orderBy("orderID", true);
		}

		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		while(stmt.step () == Sqlite.ROW)
		{
			string catID = stmt.column_text(0);

			if(feeds == null || showCategory(catID, feeds))
			{
				var tmpcategory = new Category(
					catID,
					stmt.column_text(1),
					(feeds == null) ? 0 : Utils.categoryGetUnread(catID, feeds),
					stmt.column_int(3),
					stmt.column_text(4),
					stmt.column_int(5)
				);

				tmp.add(tmpcategory);
			}
		}

		return tmp;
	}

	public Gee.List<Article> readUnfetchedArticles()
	{
		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("articleID");
		query.selectField("url");
		query.selectField("preview");
		query.selectField("html");
		query.selectField("feedID");

		query.addEqualsCondition("contentFetched", "0", true, false);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		var tmp = new Gee.LinkedList<Article>();
		while (stmt.step () == Sqlite.ROW)
		{
			tmp.add(new Article(
								stmt.column_text(0),																// articleID
								null,																									// title
								stmt.column_text(1),																// url
								stmt.column_text(4),																// feedID
								ArticleStatus.UNREAD,																// unread
								ArticleStatus.UNMARKED,															// marked
								stmt.column_text(3),																// html
								stmt.column_text(2),																// preview
								null,																									// author
								new GLib.DateTime.now_local()												// date
							));
		}

		return tmp;
	}

	public QueryBuilder articleQuery(string id, FeedListType selectedType, ArticleListState state, string searchTerm)
	{
		string orderBy = ((ArticleListSort)Settings.general().get_enum("articlelist-sort-by") == ArticleListSort.RECEIVED) ? "rowid" : "date";

		var query = new QueryBuilder(QueryType.SELECT, "articles");
		query.selectField("ROWID");
		query.selectField("feedID");
		query.selectField("articleID");
		query.selectField("title");
		query.selectField("author");
		query.selectField("url");
		query.selectField("preview");
		query.selectField("unread");
		query.selectField("marked");
		query.selectField("tags");
		query.selectField("date");
		query.selectField("guidHash");
		query.selectField("media");

		if(selectedType == FeedListType.FEED && id != FeedID.ALL.to_string())
		{
			query.addEqualsCondition("feedID", id, true, true);
		}
		else if(selectedType == FeedListType.CATEGORY && id != CategoryID.MASTER.to_string() && id != CategoryID.TAGS.to_string())
		{
			query.addRangeConditionString("feedID", getFeedIDofCategorie(id));
		}
		else if(id == CategoryID.TAGS.to_string())
		{
			query.addCustomCondition(getAllTagsCondition());
		}
		else if(selectedType == FeedListType.TAG)
		{
			query.addCustomCondition("instr(tags, \"%s\") > 0".printf(id));
		}

		if(state == ArticleListState.UNREAD)
		{
			query.addEqualsCondition("unread", ArticleStatus.UNREAD.to_string());
		}
		else if(state == ArticleListState.MARKED)
		{
			query.addEqualsCondition("marked", ArticleStatus.MARKED.to_string());
		}

		if(searchTerm != ""){
			if(searchTerm.has_prefix("title: "))
			{
				query.addCustomCondition("articleID IN (SELECT articleID FROM fts_table WHERE title MATCH '%s')".printf(Utils.prepareSearchQuery(searchTerm)));
			}
			else if(searchTerm.has_prefix("author: "))
			{
				query.addCustomCondition("articleID IN (SELECT articleID FROM fts_table WHERE author MATCH '%s')".printf(Utils.prepareSearchQuery(searchTerm)));
			}
			else if(searchTerm.has_prefix("content: "))
			{
				query.addCustomCondition("articleID IN (SELECT articleID FROM fts_table WHERE preview MATCH '%s')".printf(Utils.prepareSearchQuery(searchTerm)));
			}
			else
			{
				query.addCustomCondition("articleID IN (SELECT articleID FROM fts_table WHERE fts_table MATCH '%s')".printf(Utils.prepareSearchQuery(searchTerm)));
			}
		}

		bool desc = true;
		if(Settings.general().get_boolean("articlelist-oldest-first") && state == ArticleListState.UNREAD)
			desc = false;

		query.orderBy(orderBy, desc);

		return query;
	}

	public Gee.List<Article> read_articles(string id, FeedListType selectedType, ArticleListState state, string searchTerm, uint limit = 20, uint offset = 0, int searchRows = 0)
	{
		var query = articleQuery(id, selectedType, state, searchTerm);

		string desc = "DESC";
		if(Settings.general().get_boolean("articlelist-oldest-first") && state == ArticleListState.UNREAD)
			desc = "ASC";

		if(searchRows != 0)
		{
			string orderBy = ((ArticleListSort)Settings.general().get_enum("articlelist-sort-by") == ArticleListSort.RECEIVED) ? "rowid" : "date";
			query.addCustomCondition(@"articleID in (SELECT articleID FROM articles ORDER BY $orderBy $desc LIMIT $searchRows)");
		}

		query.limit(limit);
		query.offset(offset);
		query.build();

		Sqlite.Statement stmt = m_db.prepare(query.get());

		var tmp = new Gee.LinkedList<Article>();
		while (stmt.step () == Sqlite.ROW)
		{
			tmp.add(new Article(
								stmt.column_text(2),																		// articleID
								stmt.column_text(3),																		// title
								stmt.column_text(5),																		// url
								stmt.column_text(1),																		// feedID
								(ArticleStatus)stmt.column_int(7),											// unread
								(ArticleStatus)stmt.column_int(8),											// marked
								null,																											// html
								stmt.column_text(6),																		// preview
								stmt.column_text(4),																		// author
								new GLib.DateTime.from_unix_local(stmt.column_int(10)),	// date
								stmt.column_int(0),																			// sortID
								StringUtils.split(stmt.column_text(9), ",", true),  		// tags
								StringUtils.split(stmt.column_text(12), ",", true), 		// media
								stmt.column_text(11)																		// guid
							));
		}

		return tmp;
	}

}
