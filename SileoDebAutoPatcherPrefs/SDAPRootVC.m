#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// Same suite the tweak reads. NSUserDefaults with a suite name is the supported
// route on Roothide — roothidehooks.dylib in cfprefsd redirects the path into
// the jbroot, so Settings.app and the two jbroot apps agree.
static NSString *const kSuite = @"com.guacforlife.debautopatcher";

@interface SDAPRootVC : PSListController
@end

@implementation SDAPRootVC

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}
	return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
	[prefs setObject:value forKey:specifier.properties[@"key"]];
	[prefs synchronize];
	[super setPreferenceValue:value specifier:specifier];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
	NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
	id v = [prefs objectForKey:specifier.properties[@"key"]];
	return v ?: specifier.properties[@"default"];
}

@end
