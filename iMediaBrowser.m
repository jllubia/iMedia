/*
 
 Permission is hereby granted, free of charge, to any person obtaining a 
 copy of this software and associated documentation files (the "Software"), 
 to deal in the Software without restriction, including without limitation 
 the rights to use, copy, modify, merge, publish, distribute, sublicense, 
 and/or sell copies of the Software, and to permit persons to whom the Software 
 is furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in 
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS 
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR 
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
 AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION 
 WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 
Please send fixes to
	<ghulands@framedphotographics.com>
	<ben@scriptsoftware.com>
 
 */

#import "iMediaBrowser.h"
#import "iMediaBrowserProtocol.h"
#import "iMedia.h"
#import "LibraryItemsValueTransformer.h"

#import <QuickTime/QuickTime.h>
#import <QTKit/QTKit.h>

NSString *iMediaBrowserSelectionDidChangeNotification = @"iMediaSelectionChanged";

static iMediaBrowser *_sharedMediaBrowser = nil;
static NSMutableArray *_browserClasses = nil;
static NSMutableDictionary *_parsers = nil;

@interface iMediaBrowser (PrivateAPI)
- (void)resetLibraryController;
- (void)showMediaBrowser:(NSString *)browserClassName;
@end

@interface iMediaBrowser (Plugins)
+ (NSArray *)findBundlesWithExtension:(NSString *)ext inFolderName:(NSString *)folder;
@end

@interface NSObject (iMediaHack)
- (id)observedObject;
@end

@implementation iMediaBrowser

+ (void)load
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	_browserClasses = [[NSMutableArray alloc] init];
	_parsers = [[NSMutableDictionary dictionary] retain];
	
	//register the default set in order
	[self registerBrowser:NSClassFromString(@"iMBPhotosController")];
	[self registerBrowser:NSClassFromString(@"iMBMusicController")];
	[self registerBrowser:NSClassFromString(@"iMBMoviesController")];
	[self registerBrowser:NSClassFromString(@"iMBLinksController")];
	//[self registerBrowser:NSClassFromString(@"iMBContactsController")];
	
	//find and load all plugins
	NSArray *plugins = [iMediaBrowser findBundlesWithExtension:@"iMediaBrowser" inFolderName:@"iMediaBrowser"];
	NSEnumerator *e = [plugins objectEnumerator];
	NSString *cur;
	
	while (cur = [e nextObject])
	{
		NSBundle *b = [NSBundle bundleWithPath:cur];
		Class mainClass = [b principalClass];
		if ([mainClass conformsToProtocol:@protocol(iMediaBrowser)] || [mainClass conformsToProtocol:@protocol(iMBParser)]) 
		{
			if (![b load])
			{
				NSLog(@"Failed to load iMediaBrowser plugin: %@", cur);
				continue;
			}
		}
		else
		{
			NSLog(@"Plugin located at: %@ does not implement either of the required protocols", cur);
		}
	}
	
	[pool release];
}

+ (id)sharedBrowser
{
	if (!_sharedMediaBrowser)
		_sharedMediaBrowser = [[iMediaBrowser alloc] init];
	return _sharedMediaBrowser;
}

+ (id)sharedBrowserWithDelegate:(id)delegate
{
	iMediaBrowser *imb = [self sharedBrowser];
	[imb setDelegate:delegate];
	return imb;
}

+ (id)sharedBrowserWithDelegate:(id)delegate supportingBrowserTypes:(NSArray*)types;
{
	iMediaBrowser *imb = [self sharedBrowserWithDelegate:delegate];
	[imb setPreferredBrowserTypes:types];
	return imb;
}


+ (id)sharedBrowserWithoutLoading;
{
	return _sharedMediaBrowser;
}


+ (void)registerBrowser:(Class)aClass
{
	if (aClass != NULL)
	{
		[_browserClasses addObject:NSStringFromClass(aClass)];
	}
}

+ (void)unregisterBrowser:(Class)aClass
{
	if (aClass == NULL) return;
	NSEnumerator *e = [_browserClasses objectEnumerator];
	NSString *cur;
	while (cur = [e nextObject]) {
		Class bClass = NSClassFromString(cur);
		if (aClass == bClass) {
			[_browserClasses removeObject:cur];
			return;
		}
	}
}

+ (void)registerParser:(Class)aClass forMediaType:(NSString *)media
{
	NSAssert(aClass != NULL, @"aClass is NULL");
	NSAssert(media != nil, @"media is nil");
	
	NSMutableArray *parsers = [_parsers objectForKey:media];
	if (!parsers)
	{
		parsers = [NSMutableArray array];
		[_parsers setObject:parsers forKey:media];
	}
  if (aClass != Nil)
    [parsers addObject:NSStringFromClass(aClass)];
}

+ (void)unregisterParser:(Class)aClass forMediaType:(NSString *)media
{
	NSEnumerator *e = [[_parsers objectForKey:media] objectEnumerator];
	NSString *cur;
	while (cur = [e nextObject]) {
		Class bClass = NSClassFromString(cur);
		if (aClass == bClass) {
			[[_parsers objectForKey:media] removeObject:cur];
			return;
		}
	}
}

#pragma mark -
#pragma mark Instance Methods

- (id)init
{
	if (self = [super initWithWindowNibName:@"MediaBrowser"]) {
		
		[QTMovie initialize];
		id libraryItemsValueTransformer = [[[LibraryItemsValueTransformer alloc] init] autorelease];
		[NSValueTransformer setValueTransformer:libraryItemsValueTransformer forName:@"libraryItemsValueTransformer"];
		myBackgroundLoadingLock = [[NSLock alloc] init];

		// Make sure mainBundle (class) or app or app's delegate  implements applicationIdentifier.  Do not continue if it doesn't.
		Class cls = NSClassFromString([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSPrincipalClass"]);
		if ([cls respondsToSelector:@selector(applicationIdentifier)]
			|| [NSApp respondsToSelector:@selector(applicationIdentifier)]
			|| [[NSApp delegate] respondsToSelector:@selector(applicationIdentifier)]
			)
		{
			myFlags.unused = 1;
		}
		else
		{
			myFlags.unused = 0;
			[self release];
			return nil;
		}
	}
	return self;
}

- (void)dealloc
{
	[myUserDroppedParsers release];
	[myMediaBrowsers release];
	[myLoadedParsers release];
	[myToolbar release];
	[myBackgroundLoadingLock release];
	[myPreferredBrowserTypes release];
	[super dealloc];
}

-(id <iMediaBrowser>)selectedBrowser 
{
	return mySelectedBrowser;
}

-(void)setPreferredBrowserTypes:(NSArray*)types
{
	[myPreferredBrowserTypes autorelease];
	myPreferredBrowserTypes = [types copy];
}

- (void)awakeFromNib
{
	myMediaBrowsers = [[NSMutableArray arrayWithCapacity:[_browserClasses count]] retain];
	myLoadedParsers = [[NSMutableDictionary alloc] init];
	myUserDroppedParsers = [[NSMutableArray alloc] init];
	
	if (myFlags.orientation && ![myDelegate horizontalSplitViewForMediaBrowser:self])
	{
		[oSplitView setVertical:YES];
	}

	myToolbar = [[NSToolbar alloc] initWithIdentifier:@"iMediaBrowserToolbar"];
	
	[myToolbar setAllowsUserCustomization:NO];
	[myToolbar setShowsBaselineSeparator:YES];
	[myToolbar setSizeMode:NSToolbarSizeModeSmall];
	
	NSString *lastmySelectedBrowser = [[NSUserDefaults standardUserDefaults] objectForKey:@"iMediaBrowsermySelectedBrowser"];
	BOOL canRestoreLastSelectedBrowser = NO;

	// Load any plugins so they register
	NSEnumerator *e = [_browserClasses objectEnumerator];
	NSString *cur;
	
	while (cur = [e nextObject]) {
		Class aClass = NSClassFromString(cur);
		id <iMediaBrowser>browser = [[aClass alloc] initWithPlaylistController:libraryController];
		if (![browser conformsToProtocol:@protocol(iMediaBrowser)]) {
			NSLog(@"%@ must implement the iMediaBrowser protocol", [browser class]);
			[browser release];
			continue;
		}
		
		// if we were setup with a set of browser types, lets filter now.
		if (myPreferredBrowserTypes)
		{
			if (![myPreferredBrowserTypes containsObject:cur])
			{
				[browser release];
				continue;
			}
		}
		if (myFlags.willLoadBrowser)
		{
			if (![myDelegate iMediaBrowser:self willLoadBrowser:cur])
			{
				[browser release];
				continue;
			}
		}
		if ([lastmySelectedBrowser isEqualToString:cur])
			canRestoreLastSelectedBrowser = YES;
		
		[myMediaBrowsers addObject:browser];
		[browser release];
		if (myFlags.didLoadBrowser)
		{
			[myDelegate iMediaBrowser:self didLoadBrowser:cur];
		}
	}
	
	[myToolbar setDelegate:self];
	[[self window] setToolbar:myToolbar];
	
	//select the first browser
	if ([myMediaBrowsers count] > 0) {
		if (canRestoreLastSelectedBrowser)
		{
			[myToolbar setSelectedItemIdentifier:lastmySelectedBrowser];
			[self showMediaBrowser:lastmySelectedBrowser];
		}
		else
		{
			[myToolbar setSelectedItemIdentifier:NSStringFromClass([[myMediaBrowsers objectAtIndex:0] class])];
			[self showMediaBrowser:NSStringFromClass([[myMediaBrowsers objectAtIndex:0] class])];
		}
	}
	
	NSString *position = [[NSUserDefaults standardUserDefaults] objectForKey:@"iMediaBrowserWindowPosition"];
	if (position) {
		NSRect r = NSRectFromString(position);
		[[self window] setFrame:r display:NO];
	}
	[[self window] setDelegate:self];
	[oPlaylists setDataSource:self];
	[oPlaylists setAllowsColumnReordering:NO];
	[libraryController setSortDescriptors:nil];
	[oSplitView setDelegate:self];
	
	[libraryController addObserver:self forKeyPath:@"content" options:0 context:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(appWillQuit:)
												 name:NSApplicationWillTerminateNotification
											   object:nil];
	
	//set the splitview size
	NSArray *sizes = [[NSUserDefaults standardUserDefaults] objectForKey:@"iMBSplitViewSize"];
	if (sizes)
	{
		NSRect rect = NSRectFromString([sizes objectAtIndex:0]);
		[[[oSplitView subviews] objectAtIndex:0] setFrame:rect];
		rect = NSRectFromString([sizes objectAtIndex:1]);
		[[[oSplitView subviews] objectAtIndex:1] setFrame:rect];
		[oSplitView setNeedsDisplay:YES];
	}
}

- (void)appWillQuit:(NSNotification *)notification
{
	//we want to save the current selection to UD
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	NSIndexPath *selection = [libraryController selectionIndexPath];
	NSData *archivedSelection = [NSKeyedArchiver archivedDataWithRootObject:selection];
	[ud setObject:archivedSelection forKey:[NSString stringWithFormat:@"%@Selection", NSStringFromClass([mySelectedBrowser class])]];
	[ud setObject:[NSArray arrayWithObjects:NSStringFromRect([oPlaylists frame]), NSStringFromRect([oBrowserView frame]), nil] forKey:@"iMBSplitViewSize"];
	[ud synchronize];
}

- (id <iMediaBrowser>)browserForClassName:(NSString *)name
{
	NSEnumerator *e = [myMediaBrowsers objectEnumerator];
	id <iMediaBrowser>cur;
	
	while (cur = [e nextObject]) 
	{
		NSString *className = NSStringFromClass([cur class]);
		if ([className isEqualToString:name])
		{
			return cur;
		}
	}
	return nil;
}

- (void)showMediaBrowser:(NSString *)browserClassName
{
	if (![NSStringFromClass([mySelectedBrowser class]) isEqualToString:browserClassName])
	{
		if ([myBackgroundLoadingLock tryLock])
		{
			if (nil != mySelectedBrowser)
			{
				//we want to save the current selection to UD
				NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
				NSIndexPath *selection = [libraryController selectionIndexPath];
				NSData *archivedSelection = [NSKeyedArchiver archivedDataWithRootObject:selection];
				[ud setObject:archivedSelection forKey:[NSString stringWithFormat:@"%@Selection", NSStringFromClass([mySelectedBrowser class])]];
			}
			if (myFlags.willChangeBrowser)
			{
				[myDelegate iMediaBrowser:self willChangeToBrowser:browserClassName];
			}
			[oSplitView setHidden:YES];
			[oLoadingView setHidden:NO];
			[oLoading startAnimation:self];
			id <iMediaBrowser>browser = [self browserForClassName:browserClassName];
			NSView *view = [browser browserView];
			//remove old view
			if (nil != mySelectedBrowser)
			{
				[mySelectedBrowser didDeactivate];
				[[mySelectedBrowser browserView] removeFromSuperview];
			}
			[view setFrame:[oBrowserView bounds]];
			[oBrowserView addSubview:[view retain]];
			mySelectedBrowser = browser;
			[oPlaylists registerForDraggedTypes:[mySelectedBrowser fineTunePlaylistDragTypes:[NSArray arrayWithObject:NSFilenamesPboardType]]];
			
			//save the selected browse
			[[NSUserDefaults standardUserDefaults] setObject:NSStringFromClass([mySelectedBrowser class]) forKey:@"iMediaBrowsermySelectedBrowser"];
			myFlags.isLoading = YES;
			[NSThread detachNewThreadSelector:@selector(backgroundLoadData:) toTarget:self withObject:nil];
		}
		[myToolbar setSelectedItemIdentifier:NSStringFromClass([mySelectedBrowser class])];
	}
}

- (void)toolbarItemChanged:(id)sender
{
	[self showMediaBrowser:[sender itemIdentifier]];
}

- (void)backgroundLoadData:(id)sender
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	[self resetLibraryController];
	NSMutableArray *root = [NSMutableArray array];
	NSArray *parsers = [_parsers objectForKey:[mySelectedBrowser mediaType]];
	NSEnumerator *e = [parsers objectEnumerator];
	NSString *cur;
	NSDate *timer;
	
	while (cur = [e nextObject])
	{
		Class parserClass = NSClassFromString(cur);
		if (![parserClass conformsToProtocol:@protocol(iMBParser)])
		{
			NSLog(@"Media Parser %@ does not conform to the iMBParser protocol. Skipping parser.");
			continue;
		}
		if (myFlags.willUseParser)
		{
			if (![myDelegate iMediaBrowser:self willUseMediaParser:cur forMediaType:[mySelectedBrowser mediaType]])
			{
				continue;
			}
		}
		
		id <iMBParser>parser = [myLoadedParsers objectForKey:cur];
		if (!parser)
		{
			parser = [[parserClass alloc] init];
			if (parser == nil)
			{
				continue;
			}
			[myLoadedParsers setObject:parser forKey:cur];
			[parser release];
		}
		//set the browser the parser is in
		[parser setBrowser:mySelectedBrowser];
		
		timer = [NSDate date];
		iMBLibraryNode *library = [parser library];
#if DEBUG
		// NSLog(@"Time to load parser (%@): %.3f", NSStringFromClass(parserClass), fabs([timer timeIntervalSinceNow]));
#endif
		if (library) // it is possible for a parser to return nil if the db for it doesn't exist
		{
			[root addObject:library];
		}
		
		if (myFlags.didUseParser)
		{
			[myDelegate iMediaBrowser:self didUseMediaParser:cur forMediaType:[mySelectedBrowser mediaType]];
		}
	}
	
	// Do any user dropped folders
	NSArray *drops = [[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:@"%@Dropped", [(NSObject*)mySelectedBrowser className]]];
	e = [drops objectEnumerator];
	NSString *drop;
	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL isDir;
	Class aClass = [mySelectedBrowser parserForFolderDrop];
	
	[myUserDroppedParsers removeAllObjects]; // Clear out the old ones as otherwise we just grow and grow (and leak parsers)
	while ((drop = [e nextObject]))
	{
		if ([fm fileExistsAtPath:drop isDirectory:&isDir] && isDir)
		{
			iMBAbstractParser *parser = [[aClass alloc] initWithContentsOfFile:drop];
			[parser setBrowser:mySelectedBrowser];
			iMBLibraryNode *node = [parser parseDatabase];
			[node setParser:parser];
			[node setName:[drop lastPathComponent]];
			[node setIconName:@"folder"];
			[root addObject:node];
			[myUserDroppedParsers addObject:parser];
			[parser release];
		}
	}
	
	[libraryController setContent:root];
	[self performSelectorOnMainThread:@selector(controllerLoadedData:) withObject:self waitUntilDone:NO];
	
	[pool release];
}

- (void)recursivelyAddItemsToMenu:(NSMenu *)menu withNode:(iMBLibraryNode *)node indentation:(int)indentation
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[node name]
												  action:@selector(playlistPopupChanged:)
										   keyEquivalent:@""];
	NSImage *icon = [[NSImage alloc] initWithData:[[node icon] TIFFRepresentation]];
	[icon setScalesWhenResized:YES];
	[icon setSize:NSMakeSize(16,16)];
	[item setImage:icon];
	[icon release];
	[item setTarget:self];
	[item setRepresentedObject:node];
	[item setIndentationLevel:indentation];
	[menu addItem:item];
	[item release];
	
	NSEnumerator *e = [[node items] objectEnumerator];
	iMBLibraryNode *cur;
	
	while (cur = [e nextObject])
	{
		[self recursivelyAddItemsToMenu:menu withNode:cur indentation:indentation+1];
	}
}

- (void)updatePlaylistPopup
{
	if ([[libraryController content] count] > 0)
		[oPlaylistPopup setMenu:[self playlistMenu]];
	else
		[oPlaylistPopup removeAllItems];
	[oPlaylistPopup setEnabled:[oPlaylistPopup numberOfItems] > 0];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ((object == libraryController) && [keyPath isEqualToString:@"content"])
	{
		[self updatePlaylistPopup];
	}
}


- (void)controllerLoadedData:(id)sender
{
	[oLoadingView setHidden:YES];
	[oSplitView setHidden:NO];
	[oLoading stopAnimation:self];
	[myBackgroundLoadingLock unlock];
	if ([[libraryController content] count] > 0)
	{
		// select the previous selection
		NSData *archivedSelection = [[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:@"%@Selection", NSStringFromClass([mySelectedBrowser class])]];
		if (archivedSelection)
		{
			NSIndexPath *selection = [NSKeyedUnarchiver unarchiveObjectWithData:archivedSelection];
			[libraryController setSelectionIndexPath:selection];
		}
		else
		{
			[oPlaylists expandItem:[oPlaylists itemAtRow:0]];
		}
	}
	
	[mySelectedBrowser willActivate];
	
	if (myFlags.didChangeBrowser)
	{
		[myDelegate iMediaBrowser:self didChangeToBrowser:NSStringFromClass([mySelectedBrowser class])];
	}
	myFlags.isLoading = NO;
}

- (BOOL)isLoading
{
	return myFlags.isLoading;
}

- (NSMenu *)playlistMenu
{
	NSEnumerator *e = [[libraryController content] objectEnumerator];
	iMBLibraryNode *cur;
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"playlists"];
	
	while (cur = [e nextObject])
	{
		[self recursivelyAddItemsToMenu:menu withNode:cur indentation:0];
	}
	
	return [menu autorelease];
}

- (void)playlistPopupChanged:(id)sender
{
	iMBLibraryNode *selected = [sender representedObject];
	NSIndexPath *index = [selected indexPath];
	NSIndexPath *full = nil;
	unsigned int *idxs = (unsigned int *)malloc(sizeof(unsigned int) * ([index length] + 1));
	
	idxs[0] = [[libraryController content] indexOfObject:[selected root]];
	
	int i = 0;
	for (i = 0; i < [index length]; i++)
	{
		idxs[i+1] = [index indexAtPosition:i];
	}
	full = [NSIndexPath indexPathWithIndexes:idxs length:i+1];
	[libraryController setSelectionIndexPath:full];
	free (idxs);
}

- (void)playlistSelected:(id)sender
{
	if (myFlags.didSelectNode)
	{
		[myDelegate iMediaBrowser:self didSelectNode:[[oPlaylists itemAtRow:[sender selectedRow]] observedObject]];
	}
}

- (NSArray *)searchSelectedBrowserNodeAttribute:(NSString *)nodeKey forKey:(NSString *)key matching:(NSString *)value
{
	NSMutableArray *results = [NSMutableArray array];
	NSEnumerator *e = [[mySelectedBrowser rootNodes] objectEnumerator];
	iMBLibraryNode *cur;
	
	while (cur = [e nextObject])
	{
		[results addObjectsFromArray:[cur searchAttribute:nodeKey withKeys:[NSArray arrayWithObjects:key, nil] matching:value]];
	}
	return results;
}



- (NSArray*)addCustomFolders:(NSArray*)folders
{
	NSMutableArray *results = [NSMutableArray array];
	if ([folders count])
	{
		NSFileManager *fm = [NSFileManager defaultManager];
		BOOL isDir;
		NSEnumerator *e = [folders objectEnumerator];
		NSString *cur;
		Class aClass = [mySelectedBrowser parserForFolderDrop];
		NSMutableArray *content = [NSMutableArray arrayWithArray:[libraryController content]];
		NSMutableArray *drops = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:@"%@Dropped", [(NSObject*)mySelectedBrowser className]]]];
		
		while ((cur = [e nextObject]))
		{
			if (![drops containsObject:cur] && [fm fileExistsAtPath:cur isDirectory:&isDir] && isDir && [mySelectedBrowser allowPlaylistFolderDrop:cur])
			{
				iMBAbstractParser *parser = [[aClass alloc] initWithContentsOfFile:cur];
				iMBLibraryNode *node = [parser parseDatabase];
				[node setParser:parser];
				[node setName:[cur lastPathComponent]];
				[node setIconName:@"folder"];
				[content addObject:node];
				[results addObject:node];
				[myUserDroppedParsers addObject:parser];
				[parser release];
				
				[drops addObject:cur];
			}
		}
		
		[libraryController setContent:content];
		
		[[NSUserDefaults standardUserDefaults] setObject:drops forKey:[NSString stringWithFormat:@"%@Dropped", [(NSObject*)mySelectedBrowser className]]];
	}
	
	return results;
}

#pragma mark -
#pragma mark Delegate

- (void)setDelegate:(id)delegate
{
	myFlags.willLoadBrowser = [delegate respondsToSelector:@selector(iMediaBrowser:willLoadBrowser:)];
	myFlags.didLoadBrowser = [delegate respondsToSelector:@selector(iMediaBrowser:didLoadBrowser:)];
	myFlags.willUseParser = [delegate respondsToSelector:@selector(iMediaBrowser:willUseMediaParser:forMediaType:)];
	myFlags.didUseParser = [delegate respondsToSelector:@selector(iMediaBrowser:didUseMediaParser:forMediaType:)];
	myFlags.willChangeBrowser = [delegate respondsToSelector:@selector(iMediaBrowser:willChangeBrowser:)];	
	myFlags.didChangeBrowser = [delegate respondsToSelector:@selector(iMediaBrowser:didChangeBrowser:)];
	myFlags.didSelectNode = [delegate respondsToSelector:@selector(iMediaBrowser:didSelectNode:)];
	myFlags.orientation = [delegate respondsToSelector:@selector(horizontalSplitViewForMediaBrowser:)];
	myDelegate = delegate;	// not retained
}

- (id)delegate
{
	return myDelegate;
}

#pragma mark -
#pragma mark Window Delegate Methods

- (void)windowDidMove:(NSNotification *)aNotification
{
	NSString *pos = NSStringFromRect([[self window] frame]);
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	[ud setObject:pos forKey:@"iMediaBrowserWindowPosition"];
	[ud synchronize];
}

- (void)windowDidResize:(NSNotification *)aNotification
{
	if ([[oSplitView subviews] containsObject:oPlaylistPopup])
	{
		NSRect frame = [oPlaylistPopup frame];
		if (frame.size.height < 24)
		{
			frame.size.height = 24;
			[oPlaylistPopup setFrame:frame];
		}
	}
}

- (void)windowWillClose:(NSNotification *)aNotification
{
	[mySelectedBrowser didDeactivate];
}

- (void)windowDidBecomeKey:(NSNotification *)aNotification
{
	[mySelectedBrowser willActivate];
}

- (void)resetLibraryController
{
	int controllerCount = [[libraryController arrangedObjects] count];
	for(; controllerCount != 0;--controllerCount)
	{
		[libraryController removeObjectAtArrangedObjectIndexPath:[NSIndexPath indexPathWithIndex:controllerCount-1]];
	}
}

#pragma mark -
#pragma mark NSSplitView Delegate Methods

- (void)splitViewWillResizeSubviews:(NSNotification *)aNotification
{
	if (myFlags.inSplitViewResize) return; // stop possible recursion from NSSplitView
	myFlags.inSplitViewResize = YES;
	if (![oSplitView isVertical])
	{
		if([[oPlaylists enclosingScrollView] frame].size.height <= 50 && ![[oSplitView subviews] containsObject:oPlaylistPopup])
		{
			// select the currently selected item in the playlist
			[oPlaylistPopup selectItemWithRepresentedObject:[[libraryController selectedObjects] lastObject]];
			[oSplitView replaceSubview:[[oPlaylists enclosingScrollView] retain] with:oPlaylistPopup];
			NSRect frame = [oPlaylistPopup frame];
			frame.size.height = 24;
			[oPlaylistPopup setFrame:frame];
		}
		
		if([oPlaylistPopup frame].size.height > 50 && ![[oSplitView subviews] containsObject:oPlaylists])
		{
			[oSplitView replaceSubview:[oPlaylistPopup retain] with:[oPlaylists enclosingScrollView]];
		}
	}
	myFlags.inSplitViewResize = NO;
}

- (float)splitView:(NSSplitView *)sender constrainMinCoordinate:(float)proposedMin ofSubviewAt:(int)offset
{
	return 24;
}

- (float)splitView:(NSSplitView *)sender constrainMaxCoordinate:(float)proposedMax ofSubviewAt:(int)offset
{
	if (![sender isVertical])
		return NSHeight([sender frame]) - 200;
	else
		return NSWidth([sender frame]) - 200;
}

#pragma mark -
#pragma mark NSToolbar Delegate Methods

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar 
	 itemForItemIdentifier:(NSString *)itemIdentifier 
 willBeInsertedIntoToolbar:(BOOL)flag
{
	NSEnumerator *e = [myMediaBrowsers objectEnumerator];
	id <iMediaBrowser>cur;
	
	while (cur = [e nextObject]) 
	{
		NSString *className = NSStringFromClass([cur class]);
		if ([className isEqualToString:itemIdentifier])
		{
			NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
			[item setLabel:[cur name]];
			[item setTarget:self];
			[item setImage:[cur toolbarIcon]];
			[item setAction:@selector(toolbarItemChanged:)];
			return [item autorelease];
		}
	}
	return nil;
}

- (NSArray *)allControllerClassNames
{
	NSMutableArray *identifiers = [NSMutableArray array];
	NSEnumerator *e = [myMediaBrowsers objectEnumerator];
	id <iMediaBrowser>cur;
	
	while (cur = [e nextObject]) 
	{
		[identifiers addObject:NSStringFromClass([cur class])];
	}
	return identifiers;
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
	return [self allControllerClassNames];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
	return [self allControllerClassNames];
}

- (NSArray *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar
{
	return [self allControllerClassNames];
}

// This Code is from http://theocacao.com/document.page/130

#pragma mark -
#pragma mark NSOutlineView Hacks for Drag and Drop

- (BOOL)outlineView:(NSOutlineView *)outlineView writeItems:(NSArray *)items toPasteboard:(NSPasteboard *)pboard
{
	NSEnumerator *e = [items objectEnumerator];
	id cur;
	[pboard declareTypes:[NSArray array] owner:nil]; // clear the pasteboard incase the browser decides not to add anything
	while (cur = [e nextObject])
	{
		[mySelectedBrowser writePlaylist:[cur observedObject] toPasteboard:pboard];
	}
	return [[pboard types] count] != 0;
}

- (BOOL) outlineView: (NSOutlineView *)ov
	isItemExpandable: (id)item { return NO; }

- (int)  outlineView: (NSOutlineView *)ov
         numberOfChildrenOfItem:(id)item { return 0; }

- (id)   outlineView: (NSOutlineView *)ov
			   child:(int)index
			  ofItem:(id)item { return nil; }

- (id)   outlineView: (NSOutlineView *)ov
         objectValueForTableColumn:(NSTableColumn*)col
			  byItem:(id)item { return nil; }

- (BOOL) outlineView: (NSOutlineView *)ov
          acceptDrop: (id )info
                item: (id)item
          childIndex: (int)index
{
	BOOL doDefault = YES;
	BOOL success = [mySelectedBrowser playlistOutlineView:ov acceptDrop:info item:item childIndex:index tryDefaultHandling:&doDefault];
	if (success || !doDefault)
		return success;

    NSArray *folders = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];
	[self addCustomFolders:folders];
	
	return YES;
}

- (NSDragOperation)outlineView:(NSOutlineView *)outlineView validateDrop:(id <NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(int)index
{
	BOOL doDefault = YES;
	NSDragOperation dragOp = [mySelectedBrowser playlistOutlineView:outlineView validateDrop:info proposedItem:item proposedChildIndex:index tryDefaultHandling:&doDefault];
	
	if ((dragOp != NSDragOperationNone) || !doDefault)
		return dragOp;
		
	if ([mySelectedBrowser parserForFolderDrop])
	{
		NSPasteboard *pboard = [info draggingPasteboard];
		if ([pboard availableTypeFromArray:[NSArray arrayWithObject:NSFilenamesPboardType]])
		{
			NSArray *folders = [pboard propertyListForType:NSFilenamesPboardType];
			if ([folders count] > 0)
			{
				NSString* path = [folders objectAtIndex:0];
				NSFileManager *fm = [NSFileManager defaultManager];
				
				BOOL isDir;
				if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir && [mySelectedBrowser allowPlaylistFolderDrop:path])
				{
					[outlineView setDropItem:nil dropChildIndex:NSOutlineViewDropOnItemIndex]; // Target the whole view
					return NSDragOperationCopy;
				}
			}
		}
	}
	return NSDragOperationNone;
}

- (void)outlineView:(NSOutlineView *)olv deleteItems:(NSArray *)items
{
	NSEnumerator *e = [items objectEnumerator];
	iMBLibraryNode *cur;
	
	NSMutableArray *content = [NSMutableArray arrayWithArray:[libraryController content]];
	NSMutableArray *drops = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:@"%@Dropped", [(NSObject*)mySelectedBrowser className]]]];

	while ((cur = [e nextObject]))
	{
		// we can only delete dragged folders
		NSEnumerator *g = [myUserDroppedParsers objectEnumerator];
		id parser;
		
		while ((parser = [g nextObject]))
		{
			if ([cur parser] == parser)
			{
				[drops removeObject:[parser databasePath]];
				[myUserDroppedParsers removeObject:parser];
				[content removeObject:cur];
				break;
			}
		}
	}
	[libraryController setContent:content];
	[[NSUserDefaults standardUserDefaults] setObject:drops forKey:[NSString stringWithFormat:@"%@Dropped", [(NSObject*)mySelectedBrowser className]]];
}

@end

@implementation iMediaBrowser (Plugins)

+ (NSArray *)findModulesInDirectory:(NSString*)scanDir withExtension:(NSString *)ext
{
    NSEnumerator	*e;
    NSString		*dir;
    BOOL			isDir;
	NSMutableArray	*bundles = [NSMutableArray array];
	
    // make sure scanDir exists and is a directory.
    if (![[NSFileManager defaultManager] fileExistsAtPath:scanDir isDirectory:&isDir]) return nil;
    if (!isDir) return nil;
	
    // scan the dir for .ext directories.
    e = [[[NSFileManager defaultManager] directoryContentsAtPath:scanDir] objectEnumerator];
    while (dir = [e nextObject]) {
		if ([[dir pathExtension] isEqualToString:ext]) {
			
            [bundles addObject:[NSString stringWithFormat:@"%@/%@", scanDir, dir]];
        }
    }
	return bundles;
}


+ (NSArray *)findBundlesWithExtension:(NSString *)ext inFolderName:(NSString *)folder
{
	NSMutableArray *bundles = [NSMutableArray array];
		
    //application wrapper
    [bundles addObjectsFromArray:[iMediaBrowser findModulesInDirectory:[[NSBundle mainBundle] resourcePath]
														 withExtension:ext]];

	NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSAllDomainsMask, YES);
	NSEnumerator *e = [dirs objectEnumerator];
	NSString *cur;
	
	while (cur = [e nextObject])
	{
		[bundles addObjectsFromArray:[iMediaBrowser findModulesInDirectory:[cur stringByAppendingPathComponent:folder]
															 withExtension:ext]];
	}
	return bundles;
}

@end
