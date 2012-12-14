RAImageCache
============

## Overview

This is a simple, filesystem cache intended to eliminate duplicate requests for the same image from the internet. ARC is required.

### Use

To install, simply drop the `.h` and `.m` files in your project. To use, grab the `[RAImageCache sharedCache]` singleton, and request an image with one of the following:

	-(UIImage *) imageWithDefaultTimeoutFromUrl:(NSURL *)fromURL;
	-(UIImage *) imageFromURL:(NSURL *)fromURL withTimeout:(NSTimeInterval)timeout;


### Multithreaded

Uses Grand Central Dispatch to allow for concurrent reads and blocking writes. The shared singleton can be used safely from any thread.

### Customization

Tune to your preferences by adjusting the macros in either `RAImageCache.h` or `.m`. Particularly, you will probably want to change `CACHE_MAX_ITEMS` and `CACHE_MAX_SIZE` in `.m`. These default values specify a maximum cache capacity of 1000 items, or 10mb, whichever is reached first. 