import { StyleSheet, Text, View } from 'react-native';
import { colors, spacing, type } from '../../ui/tokens';

export function SampleScreen() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Sample</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: colors.ink,
    padding: spacing.lg,
    borderRadius: 8,
  },
  title: {
    fontSize: type.h1,
    color: '#999999',
  },
});
